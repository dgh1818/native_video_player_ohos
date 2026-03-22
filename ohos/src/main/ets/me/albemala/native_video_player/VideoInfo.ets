export class VideoInfo {
  height: number;
  width: number;
  duration: number;

  constructor(height: number, width: number, duration: number) {
    this.height = height;
    this.width = width;
    this.duration = duration;
  }

  toMap(): Map<string, number> {
    const result = new Map<string, number>();
    result.set('height', this.height);
    result.set('width', this.width);
    result.set('duration', this.duration);
    return result;
  }
}
