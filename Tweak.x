#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 全局配置变量
static BOOL g_enabled = YES;
static NSString *g_customFontName = nil;
static NSString *g_customBoldFontName = nil;
static CGFloat g_fontSizeScale = 1.0;
static NSArray *g_blacklist = nil;

// ================= [过滤逻辑] =================
static BOOL shouldBypassFont(NSString *fontName) {
    if (!fontName) return YES;
    // 防止无限递归
    if ([fontName isEqualToString:g_customFontName] || [fontName isEqualToString:g_customBoldFontName]) return YES;
    
    // 过滤图标字体、Emoji及系统必须的特殊符号
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"icon"] || 
        [lower containsString:@"emoji"] || 
        [lower containsString:@"glyph"] || 
        [lower containsString:@"assets"] || 
        [lower containsString:@"fontawesome"]) {
        return YES;
    }
    return NO;
}

static BOOL isBoldRequest(NSString *fontName, CGFloat weight) {
    if (weight >= 0.2) return YES;
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"bold"] || [lower containsString:@"heavy"] || [lower containsString:@"black"]) {
        return YES;
    }
    return NO;
}

// 缩放计算
static CGFloat getScaledSize(CGFloat originalSize) {
    return ceil(originalSize * g_fontSizeScale);
}

// ================= [UIFont 核心 Hook 层] =================
%hook UIFont

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    if (!g_enabled || shouldBypassFont(fontName)) return %orig;
    
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    return %orig(targetFont, getScaledSize(fontSize));
}

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize traits:(int)traits {
    if (!g_enabled || shouldBypassFont(fontName)) return %orig;
    
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    return %orig(targetFont, getScaledSize(fontSize), traits);
}

+ (id)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight {
    if (!g_enabled) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    return [self fontWithName:targetFont size:getScaledSize(fontSize)];
}

+ (id)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight design:(id)design {
    if (!g_enabled) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    return [self fontWithName:targetFont size:getScaledSize(fontSize)];
}

// [新增: iOS 16+ 核心适配]
+ (id)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight width:(CGFloat)width {
    if (!g_enabled) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    return [self fontWithName:targetFont size:getScaledSize(fontSize)];
}

// [新增: iOS 16+ 私有 API 拦截]
+ (id)_systemFontOfSize:(double)fontSize width:(id)width traits:(int)traits {
    if (!g_enabled) return %orig;
    return [self fontWithName:g_customFontName size:getScaledSize(fontSize)];
}

+ (id)boldSystemFontOfSize:(CGFloat)fontSize {
    if (!g_enabled) return %orig;
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    return [self fontWithName:targetFont size:getScaledSize(fontSize)];
}

+ (id)italicSystemFontOfSize:(CGFloat)fontSize {
    if (!g_enabled) return %orig;
    return [self fontWithName:g_customFontName size:getScaledSize(fontSize)];
}

+ (id)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    if (!g_enabled) return %orig;
    
    NSString *reqName = descriptor.fontAttributes[@"NSFontNameAttribute"];
    if (shouldBypassFont(reqName)) return %orig;
    
    CGFloat targetSize = size > 0 ? size : descriptor.pointSize;
    NSString *targetFont = (descriptor.symbolicTraits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    
    UIFontDescriptor *newDesc = [UIFontDescriptor fontDescriptorWithName:targetFont size:getScaledSize(targetSize)];
    return %orig(newDesc, 0);
}

%end


// ================= [初始化与内存注册] =================
%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    
    // 黑名单与极高危进程过滤
    NSArray *hardcodedBlacklist = @[
        @"com.apple.calculator", // iOS 14 缩放 Bug
        @"com.apple.photos.VideoConversionService",
        @"com.apple.springboard.SBRendererService",
        @"com.apple.Search.Framework"
    ];
    if ([hardcodedBlacklist containsObject:bundleID]) return;

    // 读取配置
    NSString *prefPath = jbroot(@"/var/mobile/Library/Preferences/com.iosdump.neofont.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    
    g_enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    if (!g_enabled) return;

    g_blacklist = prefs[@"Blacklist"] ?: @[];
    if ([g_blacklist containsObject:bundleID]) return; // 用户黑名单放行

    g_customFontName = prefs[@"CustomFont"];
    g_customBoldFontName = prefs[@"CustomBoldFont"];
    g_fontSizeScale = prefs[@"FontScale"] ? [prefs[@"FontScale"] doubleValue] : 1.0;
    
    if (!g_customFontName || g_customFontName.length == 0) return;

    // --- 核心：CoreText 内存动态注册字体 ---
    // 遍历 NeoFont 目录下的所有字体文件并注册给当前进程，实现即插即用
    NSString *fontDir = jbroot(@"/var/mobile/Library/NeoFont");
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:fontDir]) {
        NSArray *files = [fm contentsOfDirectoryAtPath:fontDir error:nil];
        for (NSString *file in files) {
            if ([file hasSuffix:@".ttf"] || [file hasSuffix:@".otf"] || [file hasSuffix:@".ttc"]) {
                NSString *fullPath = [fontDir stringByAppendingPathComponent:file];
                NSURL *fontURL = [NSURL fileURLWithPath:fullPath];
                
                CFErrorRef error;
                // 先反注册以防缓存冲突，再注册至 Process 级作用域
                CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, nil);
                CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, &error);
            }
        }
    }
    
    %init;
}
