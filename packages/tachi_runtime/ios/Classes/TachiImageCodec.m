#import "TachiImageCodec.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include "jni.h"

static const NSUInteger TachiMaxPixels = 8 * 1024 * 1024;
static const NSUInteger TachiMaxImageBytes = 8 * 1024 * 1024;

@implementation TachiImageCodec
+ (NSDictionary *)decodeImageData:(NSData *)data {
  if (!data.length || data.length > TachiMaxImageBytes) return nil;
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (!source) return nil;
  NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
  NSUInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
  NSUInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
  if (!width || !height || width > 16384 || height > 16384 || width > TachiMaxPixels / height) { CFRelease(source); return nil; }
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  if (!image) return nil;
  if (CGImageGetWidth(image) != width || CGImageGetHeight(image) != height) { CGImageRelease(image); return nil; }
  NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
  CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(rgba.mutableBytes, width, height, 8, width * 4, colors, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(colors);
  if (!context) { CGImageRelease(image); return nil; }
  // Both CGImage and bitmap data use scanline order. A UIKit display transform
  // would reverse these rows and corrupt the original source's strip offsets.
  CGContextSetBlendMode(context, kCGBlendModeCopy);
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  CGContextRelease(context); CGImageRelease(image);
  uint8_t *bytes = rgba.mutableBytes;
  NSMutableData *pixels = [NSMutableData dataWithLength:width * height * sizeof(jint)];
  jint *argb = pixels.mutableBytes;
  for (NSUInteger i = 0; i < width * height; i++) {
    uint32_t alpha = bytes[4*i+3], red = bytes[4*i], green = bytes[4*i+1], blue = bytes[4*i+2];
    if (alpha && alpha < 255) { red = MIN(255, red * 255 / alpha); green = MIN(255, green * 255 / alpha); blue = MIN(255, blue * 255 / alpha); }
    argb[i] = (jint)((alpha << 24) | (red << 16) | (green << 8) | blue);
  }
  return @{ @"width":@(width), @"height":@(height), @"pixels":pixels };
}
+ (NSData *)encodePixels:(NSData *)argb width:(NSUInteger)width height:(NSUInteger)height format:(NSString *)format quality:(NSUInteger)quality {
  if (!width || !height || width > 16384 || height > 16384 || width > TachiMaxPixels / height || argb.length != width * height * sizeof(jint) || quality > 100) return nil;
  NSString *type = [format isEqual:@"png"] ? @"public.png" : [format isEqual:@"jpeg"] ? @"public.jpeg" : [format isEqual:@"webp"] ? @"org.webmproject.webp" : nil;
  if (!type) return nil;
  NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
  const jint *pixels = argb.bytes; uint8_t *bytes = rgba.mutableBytes;
  for (NSUInteger i = 0; i < width * height; i++) {
    uint32_t pixel = (uint32_t)pixels[i], alpha = pixel >> 24;
    bytes[4*i] = ((pixel >> 16) & 255) * alpha / 255;
    bytes[4*i+1] = ((pixel >> 8) & 255) * alpha / 255;
    bytes[4*i+2] = (pixel & 255) * alpha / 255;
    bytes[4*i+3] = alpha;
  }
  CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(rgba.mutableBytes, width, height, 8, width * 4, colors, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(colors);
  if (!context) return nil;
  CGImageRef image = CGBitmapContextCreateImage(context); CGContextRelease(context);
  if (!image) return nil;
  NSMutableData *output = [NSMutableData new];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output, (__bridge CFStringRef)type, 1, NULL);
  if (!destination) { CGImageRelease(image); return nil; }
  CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@(quality / 100.0)});
  BOOL success = CGImageDestinationFinalize(destination);
  CFRelease(destination); CGImageRelease(image);
  return success && output.length && output.length <= TachiMaxImageBytes ? output : nil;
}
@end

static jintArray TachiDecodePixels(JNIEnv *env, jclass cls, jbyteArray encoded) {
  @autoreleasepool {
    if (!encoded) return NULL;
    jsize length = (*env)->GetArrayLength(env, encoded);
    if (length < 1 || length > TachiMaxImageBytes) return NULL;
    NSMutableData *input = [NSMutableData dataWithLength:(NSUInteger)length];
    (*env)->GetByteArrayRegion(env, encoded, 0, length, input.mutableBytes);
    if ((*env)->ExceptionCheck(env)) return NULL;
    NSDictionary *image = [TachiImageCodec decodeImageData:input];
    if (!image) return NULL;
    jint dimensions[2] = { [image[@"width"] intValue], [image[@"height"] intValue] };
    NSData *pixels = image[@"pixels"]; jsize count = (jsize)(pixels.length / sizeof(jint));
    jintArray result = (*env)->NewIntArray(env, count + 2);
    if (!result) return NULL;
    (*env)->SetIntArrayRegion(env, result, 0, 2, dimensions);
    (*env)->SetIntArrayRegion(env, result, 2, count, pixels.bytes);
    return result;
  }
}
static jbyteArray TachiEncodePixels(JNIEnv *env, jclass cls, jintArray pixels, jint width, jint height, jstring format, jint quality) {
  @autoreleasepool {
    if (!pixels || !format || width < 1 || height < 1 || width > 16384 || height > 16384 || (uint64_t)width * height > TachiMaxPixels || quality < 0 || quality > 100 || (*env)->GetArrayLength(env,pixels) < (uint64_t)width * height) return NULL;
    const char *value = (*env)->GetStringUTFChars(env, format, NULL);
    if (!value) return NULL;
    NSString *codec = [NSString stringWithUTF8String:value]; (*env)->ReleaseStringUTFChars(env, format, value);
    NSMutableData *input = [NSMutableData dataWithLength:(NSUInteger)width * height * sizeof(jint)];
    (*env)->GetIntArrayRegion(env, pixels, 0, width * height, input.mutableBytes);
    if ((*env)->ExceptionCheck(env)) return NULL;
    NSData *encoded = [TachiImageCodec encodePixels:input width:(NSUInteger)width height:(NSUInteger)height format:codec quality:(NSUInteger)quality];
    if (!encoded) return NULL;
    jbyteArray result = (*env)->NewByteArray(env, (jsize)encoded.length);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)encoded.length, encoded.bytes);
    return result;
  }
}
BOOL TachiRegisterImageCodec(void *environment) {
  JNIEnv *env = environment;
  jclass codec = (*env)->FindClass(env, "dev/tachibooks/engine/ImageCodec");
  if (!codec) return NO;
  JNINativeMethod methods[] = {
    {"decodeNative", "([B)[I", (void *)TachiDecodePixels},
    {"encodeNative", "([IIILjava/lang/String;I)[B", (void *)TachiEncodePixels}
  };
  jint status = (*env)->RegisterNatives(env, codec, methods, 2);
  (*env)->DeleteLocalRef(env, codec);
  return status == JNI_OK && !(*env)->ExceptionCheck(env);
}
