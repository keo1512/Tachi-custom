#import "LocalComicRarReader.h"
#import <UnrarKit/UnrarKit.h>
#import <sys/stat.h>

static int LocalComicRejectVolumeAndPassword(UINT message, LPARAM userData, LPARAM p1, LPARAM p2) {
  return message == UCM_PROCESSDATA ? 1 : -1;
}

@implementation LocalComicRarReader
+ (NSError *)failure:(NSString *)message {
  return [NSError errorWithDomain:@"TachiBooksLocalComics" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
+ (BOOL)validPath:(NSString *)path {
  if (path.length == 0 || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4096 || [path hasPrefix:@"/"] ||
      [path rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\:\0"]].location != NSNotFound) return NO;
  for (NSString *part in [path componentsSeparatedByString:@"/"]) {
    if (part.length == 0 || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
  }
  return [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
+ (NSDictionary<NSString *, NSData *> *)readData:(NSData *)data error:(NSError **)error {
  if (data.length == 0 || data.length > 100 * 1024 * 1024) {
    if (error) *error = [self failure:@"RAR trống hoặc vượt giới hạn 100 MB."]; return nil;
  }
  // Only a random app-private temporary file is written, never an archive path.
  NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".rar"]]];
  if (![data writeToURL:temporary options:NSDataWritingWithoutOverwriting error:error]) return nil;
  NSDictionary *result = nil;
  @try {
    // URKFileInfo omits redirect flags. Inspect original libunrar headers first
    // to reject RAR5 links, Unix symlinks, volumes and encrypted entries.
    struct RAROpenArchiveDataEx open = {0};
    open.ArcName = (char *)temporary.fileSystemRepresentation;
    open.OpenMode = RAR_OM_LIST; open.Callback = LocalComicRejectVolumeAndPassword;
    HANDLE handle = RAROpenArchiveEx(&open);
    if (!handle || open.OpenResult != 0 || (open.Flags & (ROADF_VOLUME | ROADF_ENCHEADERS)) != 0) {
      if (handle) RARCloseArchive(handle);
      if (error) *error = [self failure:@"RAR lỗi, mã hóa hoặc nhiều tập chưa được hỗ trợ."]; return nil;
    }
    BOOL headersValid = YES; int status = 0; NSUInteger count = 0; unsigned long long expanded = 0;
    struct RARHeaderDataEx header = {0};
    while ((status = RARReadHeaderEx(handle, &header)) == 0) {
      unsigned long long size = ((unsigned long long)header.UnpSizeHigh << 32) | header.UnpSize;
      if (++count > 10000 || header.RedirType != 0 ||
          (header.HostOS == 3 && (header.FileAttr & S_IFMT) == S_IFLNK) ||
          (header.Flags & (RHDF_SPLITBEFORE | RHDF_SPLITAFTER | RHDF_ENCRYPTED)) != 0 ||
          // DictSize is KiB in libunrar 5.91. Bound allocation before extraction,
          // independently of the expanded length of a small image entry.
          header.DictSize > 64 * 1024 ||
          size > 8 * 1024 * 1024 || expanded + size > 200 * 1024 * 1024) { headersValid = NO; break; }
      expanded += size;
      if (RARProcessFile(handle, RAR_SKIP, NULL, NULL) != 0) { headersValid = NO; break; }
      memset(&header, 0, sizeof(header));
    }
    RARCloseArchive(handle);
    if (!headersValid || status != ERAR_END_ARCHIVE || count == 0) {
      if (error) *error = [self failure:@"RAR có liên kết, tập thiếu, mục lỗi hoặc vượt giới hạn giải nén."]; return nil;
    }
    URKArchive *archive = [[URKArchive alloc] initWithURL:temporary error:error];
    if (!archive) return nil;
    if (archive.hasMultipleVolumes || archive.isPasswordProtected) {
      if (error) *error = [self failure:@"RAR mã hóa hoặc nhiều tập chưa được hỗ trợ."]; return nil;
    }
    NSArray<URKFileInfo *> *infos = [archive listFileInfo:error];
    if (!infos || infos.count == 0 || infos.count > 10000) {
      if (error && !*error) *error = [self failure:@"RAR trống hoặc có quá nhiều mục."]; return nil;
    }
    // Validate names and duplicates before bounded in-memory extraction.
    NSMutableSet<NSString *> *names = [NSMutableSet set]; long long total = 0;
    for (URKFileInfo *info in infos) {
      NSString *name = info.filename;
      if (info.isDirectory && [name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];
      if (![self validPath:name] || [names containsObject:name] || info.isEncryptedWithPassword ||
          info.uncompressedSize < 0 || info.uncompressedSize > 8 * 1024 * 1024) {
        if (error) *error = [self failure:@"RAR có đường dẫn, mục trùng, liên kết hoặc kích thước không hợp lệ."]; return nil;
      }
      [names addObject:name]; total += info.uncompressedSize;
      if (total > 200 * 1024 * 1024) { if (error) *error = [self failure:@"RAR vượt giới hạn 200 MB sau giải nén."]; return nil; }
    }
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    for (URKFileInfo *info in infos) {
      if (info.isDirectory) continue;
      NSMutableData *output = [NSMutableData data]; NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
      archive.progress = progress;
      __block BOOL exceeded = NO;
      BOOL success = [archive extractBufferedDataFromFile:info.filename error:error action:^(NSData *chunk, CGFloat percent) {
        if (chunk.length > 8 * 1024 * 1024 - output.length || output.length + chunk.length > info.uncompressedSize) {
          exceeded = YES; [progress cancel]; return;
        }
        [output appendData:chunk];
      }];
      if (!success || exceeded || output.length != info.uncompressedSize) {
        if (error) *error = [self failure:@"Không giải nén được RAR hoặc dữ liệu vượt kích thước đã khai báo."]; return nil;
      }
      files[info.filename] = output;
    }
    result = files;
  } @finally { [NSFileManager.defaultManager removeItemAtURL:temporary error:nil]; }
  return result;
}
@end
