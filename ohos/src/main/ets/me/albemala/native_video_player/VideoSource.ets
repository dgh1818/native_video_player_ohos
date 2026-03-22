import { VideoSourceType, parseVideoSourceType } from './VideoSourceType';

type VideoSourcePayload = Map<string, Object>;

export class VideoSource {
  path: string;
  type: VideoSourceType;
  headers: Record<string, string>;

  constructor(path: string, type: VideoSourceType, headers: Record<string, string>) {
    this.path = path;
    this.type = type;
    this.headers = headers;
  }

  static fromMap(payload?: Object): VideoSource | undefined {
    if (!(payload instanceof Map)) {
      return undefined;
    }

    const payloadMap = payload as VideoSourcePayload;
    const pathValue: Object | undefined = readValue(payloadMap, 'path');
    const typeValue: Object | undefined = readValue(payloadMap, 'type');
    if (typeof pathValue !== 'string' || typeof typeValue !== 'string') {
      return undefined;
    }

    const type = parseVideoSourceType(typeValue);
    if (type == null) {
      return undefined;
    }

    return new VideoSource(pathValue, type, readHeaders(readValue(payloadMap, 'headers')));
  }
}

function readValue(payload: VideoSourcePayload, key: string): Object | undefined {
  return payload.get(key);
}

function readHeaders(headersValue?: Object): Record<string, string> {
  if (!(headersValue instanceof Map)) {
    return {};
  }

  const headers: Record<string, string> = {};
  const headersMap = headersValue as Map<string, Object>;
  headersMap.forEach((value: Object, key: string) => {
    if (
      typeof value === 'string' ||
      typeof value === 'number' ||
      typeof value === 'boolean'
    ) {
      headers[key] = String(value);
    }
  });
  return headers;
}
