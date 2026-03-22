export enum VideoSourceType {
  Asset = 'asset',
  File = 'file',
  Network = 'network',
}

export function parseVideoSourceType(value: string): VideoSourceType | null {
  switch (value) {
    case VideoSourceType.Asset:
      return VideoSourceType.Asset;
    case VideoSourceType.File:
      return VideoSourceType.File;
    case VideoSourceType.Network:
      return VideoSourceType.Network;
    default:
      return null;
  }
}
