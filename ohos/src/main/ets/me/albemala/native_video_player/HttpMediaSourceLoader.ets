import media from '@ohos.multimedia.media';
import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';

const RANGE_BYTES = 8 * 1024 * 1024;
const PUSH_BYTES = 128 * 1024;
const MAX_OPEN_RESOURCES = 4;

class ResourceRead {
  uuid: number;
  request: media.MediaSourceLoadingRequest;
  url: string;
  headers: Record<string, string> = {};
  generation: number = 0;
  reading: boolean = false;
  readStart: number = 0;
  offset: number = 0;
  end: number | null = null; // Exclusive; null means read to verified EOF.
  emptyRead: boolean = false;
  total: number | null = null;
  contentType: string = 'application/octet-stream';
  headerSent: boolean = false;
  buffer: ArrayBuffer | null = null;
  bufferOffset: number = 0;
  client: http.HttpRequest | null = null;
  timer: number | null = null;

  constructor(uuid: number, request: media.MediaSourceLoadingRequest) {
    this.uuid = uuid;
    this.request = request;
    this.url = request.url;
    const headers = request.header;
    if (headers) {
      Object.keys(headers).forEach((key: string) => {
        this.headers[key] = headers[key];
      });
    }
  }
}

// API 26 loader for an immutable Range-capable file, with at most four 8 MiB
// buffers. Each event-loop task pushes at most 128 KiB through synchronous IPC.
export class HttpMediaSourceLoader implements media.MediaSourceLoader {
  private static nextUuid: number = 1;
  private resources: Map<number, ResourceRead> = new Map<number, ResourceRead>();
  private disposed: boolean = false;

  open = (request: media.MediaSourceLoadingRequest): number => {
    if (this.disposed || this.resources.size >= MAX_OPEN_RESOURCES ||
      !/^https?:\/\//i.test(request.url) || HttpMediaSourceLoader.nextUuid >= Number.MAX_SAFE_INTEGER) {
      return -1;
    }
    const uuid = HttpMediaSourceLoader.nextUuid++;
    this.resources.set(uuid, new ResourceRead(uuid, request));
    return uuid;
  };

  read = (uuid: number, requestedOffset: number, requestedLength: number): void => {
    const resource = this.resources.get(uuid);
    if (!resource || this.disposed) return;
    this.cancelTransfer(resource);
    resource.reading = true;
    const generation = resource.generation;
    const valid = Number.isSafeInteger(requestedOffset) && requestedOffset >= 0 &&
      Number.isSafeInteger(requestedLength) && requestedLength >= -1 &&
      (requestedLength === -1 || requestedLength <= Number.MAX_SAFE_INTEGER - requestedOffset);
    if (!valid) {
      resource.timer = setTimeout(() => {
        if (this.isCurrent(resource, generation)) {
          resource.timer = null;
          this.finish(resource, media.LoadingRequestError.LOADING_ERROR_NOT_READY);
        }
      }, 0);
      return;
    }
    resource.readStart = requestedOffset;
    resource.offset = requestedOffset;
    resource.end = requestedLength === -1 ? null : requestedOffset + requestedLength;
    resource.emptyRead = requestedLength === 0;
    resource.headerSent = false;
    const buffer = resource.buffer;
    if (buffer && (requestedOffset < resource.bufferOffset ||
      requestedOffset >= resource.bufferOffset + buffer.byteLength)) {
      resource.buffer = null;
    }
    this.schedule(resource);
  };

  close = (uuid: number): void => {
    const resource = this.resources.get(uuid);
    if (!resource) return;
    this.resources.delete(uuid); // Invalidate first, including reentrant late callbacks.
    this.cancelTransfer(resource);
    resource.reading = false;
    resource.buffer = null;
  };

  dispose(): void {
    this.disposed = true;
    this.resources.forEach((resource: ResourceRead) => this.close(resource.uuid));
  }

  private isCurrent(resource: ResourceRead, generation: number): boolean {
    return !this.disposed && this.resources.get(resource.uuid) === resource &&
      resource.generation === generation && resource.reading;
  }

  private cancelTransfer(resource: ResourceRead): void {
    resource.generation++;
    if (resource.timer !== null) clearTimeout(resource.timer);
    resource.timer = null;
    const client = resource.client;
    resource.client = null;
    if (client) {
      try {
        client.destroy();
      } catch (_) {
        // The generation is already invalid even if native disposal throws.
      }
    }
  }

  private schedule(resource: ResourceRead): void {
    if (resource.timer !== null || !resource.reading) return;
    const generation = resource.generation;
    resource.timer = setTimeout(() => {
      if (!this.isCurrent(resource, generation)) return;
      resource.timer = null;
      try {
        this.pump(resource, generation);
      } catch (_) {
        if (this.isCurrent(resource, generation)) {
          this.finish(resource, media.LoadingRequestError.LOADING_ERROR_NOT_READY);
        }
      }
    }, 0);
  }

  private pump(resource: ResourceRead, generation: number): void {
    if (!resource.emptyRead && resource.end !== null && resource.offset >= resource.end) {
      // RespondData completes finite windows; a duplicate FinishLoading may end the next read.
      resource.reading = false;
      resource.buffer = null;
      return;
    }
    if (resource.total !== null && resource.offset >= resource.total) {
      this.sendHeader(resource);
      if (!this.isCurrent(resource, generation)) return;
      this.finish(resource, resource.offset === resource.total ?
        media.LoadingRequestError.LOADING_ERROR_SUCCESS : media.LoadingRequestError.LOADING_ERROR_NO_RESOURCE);
      return;
    }
    // Zero length before EOF is not a documented read request.
    if (resource.emptyRead) {
      this.finish(resource, media.LoadingRequestError.LOADING_ERROR_NOT_READY);
      return;
    }
    const buffer = resource.buffer;
    if (!buffer) {
      if (!resource.client) this.fetchRange(resource, generation);
      return;
    }
    this.sendHeader(resource);
    if (!this.isCurrent(resource, generation)) return;
    const index = resource.offset - resource.bufferOffset;
    const count = Math.min(PUSH_BYTES, buffer.byteLength - index,
      resource.end === null ? PUSH_BYTES : resource.end - resource.offset);
    const accepted = resource.request.respondData(resource.uuid, resource.offset, buffer.slice(index, index + count));
    if (!this.isCurrent(resource, generation)) return;
    if (accepted === -2) {
      resource.reading = false;
      resource.buffer = null;
      return;
    }
    if (accepted === -3 || accepted === 0) {
      // Keep this bounded buffer; next read supplies the authoritative resume offset.
      resource.reading = false;
      return;
    }
    if (!Number.isSafeInteger(accepted) || accepted < 0 || accepted > count) {
      this.finish(resource, media.LoadingRequestError.LOADING_ERROR_NOT_READY);
      return;
    }
    resource.offset += accepted; // Advance only by the bytes actually accepted.
    if (resource.offset === resource.bufferOffset + buffer.byteLength) resource.buffer = null;
    this.schedule(resource);
  }

  private async fetchRange(resource: ResourceRead, generation: number): Promise<void> {
    const start = resource.offset;
    const end = Math.min(start + Math.min(RANGE_BYTES, Number.MAX_SAFE_INTEGER - start),
      resource.end ?? Number.MAX_SAFE_INTEGER, resource.total ?? Number.MAX_SAFE_INTEGER) - 1;
    if (end < start) {
      this.finish(resource, media.LoadingRequestError.LOADING_ERROR_NOT_READY);
      return;
    }
    let client: http.HttpRequest | null = null;
    const started = Date.now();
    try {
      client = http.createHttp();
      resource.client = client;
      const headers: Record<string, string> = {};
      Object.keys(resource.headers).forEach((key: string) => {
        const lower = key.toLowerCase();
        if (lower !== 'range' && lower !== 'accept-encoding' && lower !== 'connection' &&
          lower !== 'proxy-connection' && lower !== 'transfer-encoding') {
          headers[key] = resource.headers[key];
        }
      });
      // Do not use resumeFrom/resumeTo: their SDK range is limited to 4 GiB.
      headers['Range'] = `bytes=${start}-${end}`;
      headers['Accept-Encoding'] = 'identity';
      console.info(`HttpMediaSourceLoader request id=${resource.uuid} gen=${generation} start=${start} end=${end}`);
      const response = await client.request(resource.url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        reuseConnections: true,
        usingCache: false,
        maxLimit: RANGE_BYTES,
        maxRedirects: 0,
        connectTimeout: 5000,
        readTimeout: 10000,
      });
      if (!this.isCurrent(resource, generation)) return;
      const version = /^HTTP\/([0-9.]+)\s/i.exec(this.header(response.header, 'status-line'));
      console.info(`HttpMediaSourceLoader response id=${resource.uuid} gen=${generation} status=${response.responseCode} http=${version ? version[1] : 'unknown'} elapsedMs=${Date.now() - started}`);
      this.acceptResponse(resource, response, start, end);
    } catch (error) {
      if (this.isCurrent(resource, generation)) {
        const code = (error as BusinessError).code;
        this.finish(resource, code === 2300028 ? media.LoadingRequestError.LOADING_ERROR_ACCESS_TIMEOUT :
          media.LoadingRequestError.LOADING_ERROR_NOT_READY);
      }
    } finally {
      // A stale Promise must not destroy the replacement request.
      if (client && resource.client === client) {
        resource.client = null;
        try { client.destroy(); } catch (_) {}
      }
    }
    if (this.isCurrent(resource, generation)) this.schedule(resource);
  }

  private acceptResponse(resource: ResourceRead, response: http.HttpResponse, start: number, end: number): void {
    const contentRange = this.header(response.header, 'content-range');
    if (response.responseCode === 416) {
      const match = /^bytes\s+\*\/(\d+)$/i.exec(contentRange);
      const total = match ? Number(match[1]) : -1;
      if (!Number.isSafeInteger(total) || total < 0 || start !== total ||
        (resource.total !== null && resource.total !== total)) {
        this.finish(resource, media.LoadingRequestError.LOADING_ERROR_NO_RESOURCE);
        return;
      }
      resource.total = total;
      return; // The next pump sends metadata and EOF, with no response body.
    }
    if (response.responseCode !== 206) {
      let error = media.LoadingRequestError.LOADING_ERROR_NOT_READY;
      if (response.responseCode === 401) error = media.LoadingRequestError.LOADING_ERROR_AUTHORIZE_FAILED;
      if (response.responseCode === 403) error = media.LoadingRequestError.LOADING_ERROR_ACCESS_DENIED;
      if (response.responseCode === 404) error = media.LoadingRequestError.LOADING_ERROR_NO_RESOURCE;
      this.finish(resource, error);
      return;
    }
    const match = /^bytes\s+(\d+)-(\d+)\/(\d+)$/i.exec(contentRange);
    if (!match) throw new Error('Invalid Content-Range');
    const first = Number(match[1]);
    const last = Number(match[2]);
    const total = Number(match[3]);
    if (!Number.isSafeInteger(first) || !Number.isSafeInteger(last) || !Number.isSafeInteger(total) ||
      first !== start || total <= first || last !== Math.min(end, total - 1) ||
      (resource.total !== null && resource.total !== total)) {
      throw new Error('Mismatched Content-Range');
    }
    const encoding = this.header(response.header, 'content-encoding').toLowerCase();
    if (encoding !== '' && encoding !== 'identity') throw new Error('Encoded range is not byte-addressable');
    const length = last - first + 1;
    const declared = this.header(response.header, 'content-length');
    if (declared !== '' && (!/^\d+$/.test(declared) || Number(declared) !== length)) {
      throw new Error('Mismatched Content-Length');
    }
    if (!(response.result instanceof ArrayBuffer) || response.result.byteLength !== length || length > RANGE_BYTES) {
      throw new Error('Incomplete or oversized range');
    }
    resource.total = total;
    resource.contentType = this.header(response.header, 'content-type') || 'application/octet-stream';
    resource.bufferOffset = start;
    resource.buffer = response.result;
  }

  private header(headers: Object, name: string): string {
    const values: Record<string, string> = typeof headers === 'string' ?
      JSON.parse(headers) as Record<string, string> : headers as Record<string, string>;
    const keys = Object.keys(values);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === name) return String(values[keys[i]]).trim();
    }
    return '';
  }

  private sendHeader(resource: ResourceRead): void {
    if (resource.headerSent || resource.total === null) return;
    // Native read-window length and full file size differ from the HTTP chunk size.
    const start = resource.readStart;
    const end = Math.min(resource.end ?? resource.total, resource.total);
    const length = Math.max(0, end - start);
    const range = length > 0 ? `bytes ${start}-${end - 1}/${resource.total}` : '';
    resource.headerSent = true;
    const headers: Record<string, string> = {
      'content-length': `${length}`,
      'accept-ranges': 'bytes',
      'content-type': resource.contentType,
    };
    // AppClient cannot parse a 416 wildcard interval at EOF.
    if (length > 0) headers['content-range'] = range;
    resource.request.respondHeader(resource.uuid, headers);
  }

  private finish(resource: ResourceRead, error: media.LoadingRequestError): void {
    console.info(`HttpMediaSourceLoader finish id=${resource.uuid} gen=${resource.generation} offset=${resource.offset} code=${error}`);
    resource.reading = false;
    resource.buffer = null;
    this.cancelTransfer(resource);
    try {
      resource.request.finishLoading(resource.uuid, error);
    } catch (_) {
      // A released native handle must not escape as an unhandled rejection.
    }
  }
}
