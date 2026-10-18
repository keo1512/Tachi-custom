#import "TachiRuntimePlugin.h"
#import "TachiSourceBrowser.h"
#import <dlfcn.h>
#include <TargetConditionals.h>
#include <stdlib.h>
#include <string.h>
#include "jni.h"

// A JVM is process-wide. Java serializes mutations and permits bounded cover
// reads in parallel; its JNIEnv remains
// thread-local even when GCD chooses a different thread for the next request.
static JavaVM *tachiVM;
static jclass tachiHost;
static jmethodID tachiInvoke;
static void *tachiLibrary;
static dispatch_queue_t tachiQueue;
static NSString *tachiStartupError;

@implementation TachiRuntimePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  static dispatch_once_t queueOnce;
  dispatch_once(&queueOnce, ^{
    tachiQueue = dispatch_queue_create("dev.tachibooks.tachi-runtime", DISPATCH_QUEUE_CONCURRENT);
  });
  FlutterMethodChannel *channel = [FlutterMethodChannel
    methodChannelWithName:@"dev.tachibooks/tachi_runtime"
    binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:[[TachiRuntimePlugin alloc] init] channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"openSourceBrowser"]) {
    if (![call.arguments isKindOfClass:NSDictionary.class]) {
      result([FlutterError errorWithCode:@"INVALID_SOURCE_URL" message:@"Thiếu phiên nguồn." details:nil]);
      return;
    }
    [TachiSourceBrowser openOptions:call.arguments result:result];
    return;
  }
  if ([call.method isEqualToString:@"openBrowser"]) {
    if (![call.arguments isKindOfClass:NSString.class]) {
      result([FlutterError errorWithCode:@"INVALID_SOURCE_URL" message:@"Thiếu địa chỉ nguồn." details:nil]);
      return;
    }
    [TachiSourceBrowser openURL:call.arguments result:result];
    return;
  }
  if (![call.method isEqualToString:@"invoke"]) {
    result(FlutterMethodNotImplemented);
    return;
  }
  if (![call.arguments isKindOfClass:NSString.class] ||
      [(NSString *)call.arguments lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16 * 1024 * 1024) {
    result([FlutterError errorWithCode:@"INVALID_RUNTIME_REQUEST"
                             message:@"Yêu cầu engine không hợp lệ." details:nil]);
    return;
  }
  NSString *request = call.arguments;
  dispatch_async(tachiQueue, ^{
    @autoreleasepool {
      NSError *error = nil;
      NSString *response = [self invoke:request error:&error];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
          result([FlutterError errorWithCode:@"TACHI_RUNTIME_FAILED"
                                   message:error.localizedDescription details:nil]);
        } else {
          result(response);
        }
      });
    }
  });
}

- (BOOL)fail:(NSString *)message error:(NSError **)error {
  if (error) *error = [NSError errorWithDomain:@"dev.tachibooks.tachi-runtime"
                                       code:1
                                   userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

- (BOOL)start:(NSError **)error {
  if (tachiVM && tachiHost && tachiInvoke) return YES;
  if (tachiStartupError) return [self fail:tachiStartupError error:error];
#if TARGET_OS_SIMULATOR
  return [self fail:@"JVM hiện được đóng gói cho iPhone/iPad arm64; simulator không nạp binary thiết bị."
               error:error];
#else
  NSBundle *plugin = [NSBundle bundleForClass:TachiRuntimePlugin.class];
  NSURL *resource = [plugin URLForResource:@"TachiRuntime" withExtension:@"bundle"];
  if (!resource) resource = [NSBundle.mainBundle URLForResource:@"TachiRuntime" withExtension:@"bundle"];
  NSBundle *bundle = resource ? [NSBundle bundleWithURL:resource] : nil;
  NSString *jre = [bundle.resourcePath stringByAppendingPathComponent:@"jre"];
  NSString *engine = [bundle.resourcePath stringByAppendingPathComponent:@"engine"];
  NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
  NSString *library = [frameworks stringByAppendingPathComponent:@"TachiJVM.framework/TachiJVM"];
  if (!bundle || ![NSFileManager.defaultManager fileExistsAtPath:library]) {
    tachiStartupError = @"Bản build thiếu runtime Java dành cho thiết bị.";
    return [self fail:tachiStartupError error:error];
  }
  // Load bundled code normally. No JIT, entitlement changes, or library
  // validation bypass. The packaged libraries require normal iOS code signing.
  tachiLibrary = dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  typedef jint (*CreateVM)(JavaVM **, void **, void *);
  CreateVM createVM = tachiLibrary ? (CreateVM)dlsym(tachiLibrary, "JNI_CreateJavaVM") : NULL;
  if (!createVM) {
    const char *detail = dlerror();
    tachiStartupError = [NSString stringWithFormat:@"Không nạp được JVM đã đóng gói: %s", detail ?: "JNI_CreateJavaVM missing"];
    return [self fail:tachiStartupError error:error];
  }
  NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
  NSURL *data = [support URLByAppendingPathComponent:@"TachiBooks/extension-runtime" isDirectory:YES];
  NSURL *temporary = [data URLByAppendingPathComponent:@"tmp" isDirectory:YES];
  if (![NSFileManager.defaultManager createDirectoryAtURL:temporary withIntermediateDirectories:YES
                                               attributes:nil error:error]) return NO;
  NSMutableArray<NSString *> *bootstrap = [NSMutableArray new];
  for (NSString *name in @[@"resources.jar", @"rt.jar", @"jsse.jar", @"jce.jar", @"charsets.jar", @"jfr.jar"]) {
    NSString *path = [[jre stringByAppendingPathComponent:@"lib"] stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
      return [self fail:@"Bản build thiếu thư viện khởi động Java." error:error];
    }
    [bootstrap addObject:path];
  }
  NSArray<NSString *> *values = @[
    @"-Xint", @"-Xms16m", @"-Xmx128m", @"-Xss512k",
    @"-XX:-UseCompressedOops", @"-XX:-UseCompressedClassPointers",
    [@"-Djava.home=" stringByAppendingString:jre],
    [@"-Xbootclasspath:" stringByAppendingString:[bootstrap componentsJoinedByString:@":"]],
    [@"-Dsun.boot.library.path=" stringByAppendingString:frameworks],
    [@"-Djava.ext.dirs=" stringByAppendingString:[jre stringByAppendingPathComponent:@"lib/ext"]],
    [@"-Djava.class.path=" stringByAppendingString:[NSString stringWithFormat:@"%@/extension-host.jar:%@/extension-dependencies.jar", engine, engine]],
    [@"-Djava.library.path=" stringByAppendingString:frameworks],
    [@"-Djava.io.tmpdir=" stringByAppendingString:temporary.path],
    [@"-Duser.home=" stringByAppendingString:data.path],
    [@"-Duser.dir=" stringByAppendingString:data.path],
    @"-Djava.awt.headless=true"
  ];
  JavaVMOption *options = calloc(values.count, sizeof(JavaVMOption));
  if (!options) return [self fail:@"Không đủ bộ nhớ để mở engine." error:error];
  for (NSUInteger index = 0; index < values.count; index++) {
    options[index].optionString = strdup(values[index].UTF8String);
    if (!options[index].optionString) {
      for (NSUInteger previous = 0; previous < index; previous++) free(options[previous].optionString);
      free(options);
      return [self fail:@"Không đủ bộ nhớ để mở engine." error:error];
    }
  }
  JavaVMInitArgs arguments = {0};
  arguments.version = JNI_VERSION_1_8;
  arguments.nOptions = (jint)values.count;
  arguments.options = options;
  arguments.ignoreUnrecognized = JNI_FALSE;
  JNIEnv *env = NULL;
  jint status = createVM(&tachiVM, (void **)&env, &arguments);
  for (NSUInteger index = 0; index < values.count; index++) free(options[index].optionString);
  free(options);
  if (status != JNI_OK || !env) {
    tachiStartupError = [NSString stringWithFormat:@"JVM không khởi động được (mã %d).", status];
    return [self fail:tachiStartupError error:error];
  }
  jclass localHost = (*env)->FindClass(env, "dev/tachibooks/engine/ExtensionHost");
  if (localHost) {
    tachiHost = (*env)->NewGlobalRef(env, localHost);
    (*env)->DeleteLocalRef(env, localHost);
    if (tachiHost && !(*env)->ExceptionCheck(env)) {
      tachiInvoke = (*env)->GetStaticMethodID(env, tachiHost, "invoke", "(Ljava/lang/String;)Ljava/lang/String;");
    }
  }
  if ((*env)->ExceptionCheck(env) || !tachiHost || !tachiInvoke) {
    (*env)->ExceptionClear(env);
    (*tachiVM)->DetachCurrentThread(tachiVM);
    tachiStartupError = @"Runtime thiếu class hoặc entrypoint engine tương thích.";
    return [self fail:tachiStartupError error:error];
  }
  // GCD may use another thread for the next invocation. Release the creator
  // thread's attachment now; invoke attaches/detaches its actual worker below.
  (*tachiVM)->DetachCurrentThread(tachiVM);
  return YES;
#endif
}

- (NSString *)invoke:(NSString *)request error:(NSError **)error {
  @synchronized([TachiRuntimePlugin class]) {
    if (![self start:error]) return nil;
  }
  JNIEnv *env = NULL;
  jint status = (*tachiVM)->GetEnv(tachiVM, (void **)&env, JNI_VERSION_1_8);
  BOOL attached = status == JNI_EDETACHED;
  if (attached) status = (*tachiVM)->AttachCurrentThread(tachiVM, (void **)&env, NULL);
  if (status != JNI_OK || !env) {
    [self fail:@"Không gắn được worker vào engine Java." error:error];
    return nil;
  }
  // JNI modified UTF-8 differs from UTF-8 for NUL and supplementary characters.
  // Bridge UTF-16 directly so Vietnamese names and emoji retain their bytes.
  NSUInteger count = request.length;
  unichar *characters = malloc(MAX((NSUInteger)1, count) * sizeof(unichar));
  if (!characters) {
    if (attached) (*tachiVM)->DetachCurrentThread(tachiVM);
    [self fail:@"Không đủ bộ nhớ để gửi yêu cầu nguồn." error:error];
    return nil;
  }
  [request getCharacters:characters range:NSMakeRange(0, count)];
  jstring input = (*env)->NewString(env, (const jchar *)characters, (jsize)count);
  free(characters);
  jstring output = input ? (jstring)(*env)->CallStaticObjectMethod(env, tachiHost, tachiInvoke, input) : NULL;
  if (input) (*env)->DeleteLocalRef(env, input);
  NSString *response = nil;
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    [self fail:@"Engine Java không thực hiện được yêu cầu." error:error];
  } else if (output) {
    jsize length = (*env)->GetStringLength(env, output);
    if (length > 16 * 1024 * 1024) {
      [self fail:@"Dữ liệu engine vượt giới hạn." error:error];
    } else {
      const jchar *result = (*env)->GetStringChars(env, output, NULL);
      if (result) {
        response = [[NSString alloc] initWithCharacters:(const unichar *)result length:length];
        (*env)->ReleaseStringChars(env, output, result);
      } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        [self fail:@"Không đủ bộ nhớ để đọc kết quả nguồn." error:error];
      }
    }
    (*env)->DeleteLocalRef(env, output);
  }
  if (!response && (!error || !*error)) [self fail:@"Engine trả dữ liệu rỗng." error:error];
  if (attached) (*tachiVM)->DetachCurrentThread(tachiVM);
  return response;
}
@end
