import { fileIo as fs, hash } from '@kit.CoreFileKit';
import { zlib, request, BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

export interface AssetFile {
  path: string;
  size: number;
  sha256: string;
}

export interface AssetManifest {
  pet: string;
  pet_name: string;
  platform: string;
  asset_version: string;
  release_tag: string;
  url: string;
  sha256: string;
  size: number;
  uncompressed_size: number;
  files: AssetFile[];
}

export interface AssetFd {
  fd: number;
  offset: number;
  length: number;
}

/**
 * 角色素材（Spine/语音）不随 HAP 分发：manifest 在 rawfile，
 * 素材包下载/手动导入后落到 filesDir/plugins/<pet>/<version>/。
 */
export class AssetStore {
  readonly manifest: AssetManifest;
  readonly pluginDir: string;
  private context: common.UIAbilityContext;
  private downloadTask: request.DownloadTask | null = null;
  private downloadCancelled: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.manifest = AssetStore.loadManifest(context);
    this.pluginDir = context.filesDir + '/plugins/' + this.manifest.pet + '/' + this.manifest.asset_version;
  }

  static loadManifest(context: common.UIAbilityContext): AssetManifest {
    let raw = context.resourceManager.getRawFileContentSync('asset_manifest.json');
    let decoder = util.TextDecoder.create('utf-8');
    let text = decoder.decodeToString(raw);
    return JSON.parse(text) as AssetManifest;
  }

  file(relative: string): string {
    return this.pluginDir + '/' + relative;
  }

  isInstalledSync(): boolean {
    for (let i = 0; i < this.manifest.files.length; i++) {
      let item = this.manifest.files[i];
      let path = this.file(item.path);
      try {
        let stat = fs.statSync(path);
        if (!fs.accessSync(path) || stat.size !== item.size) {
          return false;
        }
      } catch (e) {
        return false;
      }
    }
    return true;
  }

  readText(relative: string): string {
    return fs.readTextSync(this.file(relative));
  }

  readBytes(relative: string): Uint8Array {
    let path = this.file(relative);
    let stat = fs.statSync(path);
    let buffer = new ArrayBuffer(stat.size);
    let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    return new Uint8Array(buffer);
  }

  openFd(relative: string): AssetFd {
    let path = this.file(relative);
    let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let stat = fs.statSync(path);
    return { fd: file.fd, offset: 0, length: stat.size };
  }

  closeFd(fd: number): void {
    try {
      fs.closeSync(fd);
    } catch (e) {
    }
  }

  async hashOf(path: string): Promise<string> {
    return await hash.hash(path, 'sha256');
  }

  async download(url: string, dest: string, onProgress: (done: number, total: number) => void): Promise<void> {
    try {
      if (fs.accessSync(dest)) {
        fs.unlinkSync(dest);
      }
    } catch (e) {
    }
    this.downloadCancelled = false;
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
      let config: request.DownloadConfig = {
        url: url,
        header: { 'User-Agent': 'AngelinaPet-AssetInstaller/1.0' },
        filePath: dest
      };
      request.downloadFile(this.context, config).then((task: request.DownloadTask) => {
        this.downloadTask = task;
        task.on('progress', (received: number, total: number) => {
          onProgress(received, total);
        });
        task.on('complete', () => {
          this.downloadTask = null;
          if (this.downloadCancelled) {
            reject(new Error('已取消下载'));
          } else {
            resolve();
          }
        });
        task.on('fail', (err: number) => {
          this.downloadTask = null;
          reject(new Error('下载失败：' + err));
        });
      }).catch((err: BusinessError) => {
        this.downloadTask = null;
        reject(new Error(err.message));
      });
    });
  }

  async cancelDownload(): Promise<void> {
    if (this.downloadTask === null) {
      return;
    }
    this.downloadCancelled = true;
    try {
      await this.downloadTask.delete();
    } catch (e) {
    }
    this.downloadTask = null;
  }

  async installFromZip(
    zipPath: string,
    checkHash: boolean,
    onProgress?: (percent: number) => void
  ): Promise<void> {
    if (checkHash) {
      let actual = await this.hashOf(zipPath);
      if (actual.toLowerCase() !== this.manifest.sha256.toLowerCase()) {
        throw new Error('zip 的 SHA-256 与素材清单不一致');
      }
    }
    let temp = this.context.cacheDir + '/asset_extract_' + Date.now();
    if (fs.accessSync(temp)) {
      removeTree(temp);
    }
    fs.mkdirSync(temp, true);
    try {
      await zlib.decompressFile(zipPath, temp);
      for (let i = 0; i < this.manifest.files.length; i++) {
        let item = this.manifest.files[i];
        let src = temp + '/' + item.path;
        if (!fs.accessSync(src)) {
          throw new Error('缺少文件：' + item.path);
        }
        let stat = fs.statSync(src);
        if (stat.size !== item.size) {
          throw new Error('文件大小不符：' + item.path);
        }
        let actual = await this.hashOf(src);
        if (actual.toLowerCase() !== item.sha256.toLowerCase()) {
          throw new Error('文件内容校验失败：' + item.path);
        }
        if (onProgress !== undefined) {
          onProgress((i + 1) * 100 / this.manifest.files.length);
        }
      }

      if (!fs.accessSync(this.pluginDir)) {
        fs.mkdirSync(this.pluginDir, true);
      }
      for (let i = 0; i < this.manifest.files.length; i++) {
        let item = this.manifest.files[i];
        let src = temp + '/' + item.path;
        let dst = this.file(item.path);
        ensureParent(dst);
        if (fs.accessSync(dst)) {
          fs.unlinkSync(dst);
        }
        fs.copyFileSync(src, dst);
      }
      let marker = this.pluginDir + '/.installed.json';
      let file = fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify({
          asset_version: this.manifest.asset_version,
          sha256: this.manifest.sha256
        }));
      } finally {
        fs.closeSync(file);
      }
    } finally {
      removeTree(temp);
    }
  }
}

function ensureParent(path: string): void {
  let idx = path.lastIndexOf('/');
  if (idx > 0) {
    let dir = path.substring(0, idx);
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
  }
}

function removeTree(path: string): void {
  try {
    let names = fs.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      let child = path + '/' + names[i];
      let stat = fs.statSync(child);
      if (stat.isDirectory()) {
        removeTree(child);
      } else {
        fs.unlinkSync(child);
      }
    }
    fs.rmdirSync(path);
  } catch (e) {
  }
}
