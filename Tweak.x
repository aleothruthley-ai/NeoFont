#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ================= [全局配置变量] =================
static BOOL g_enabled = YES;
static NSString *g_customFontName = nil;
static NSString *g_customBoldFontName = nil;
static CGFloat g_fontSizeScale = 1.0;
static NSArray *g_blacklist = nil;
static BOOL g_isSpringBoard = NO;

// ================= [安全过滤逻辑] =================
static BOOL shouldBypassFont(NSString *fontName, CGFloat size) {
    if (!fontName) return YES;
    
    // 防止无限递归
    if ([fontName isEqualToString:g_customFontName] || [fontName isEqualToString:g_customBoldFontName]) return YES;
    
    // 保护 iOS 16/17 锁屏时间 (CSProminentTimeView) 和巨型排版
    // 凡是 SpringBoard 里字号超大(>=80)的，一律不碰，防止排版崩溃
    if (g_isSpringBoard && size >= 80.0) {
        return YES;
    }
    
    // 过滤图标字体、Emoji及系统必须的特殊符号
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"icon"] || 
        [lower containsString:@"emoji"] || 
        [lower containsString:@"glyph"] || 
        [lower containsString:@"assets"] || 
        [lower containsString:@"weather"] || 
        [lower containsString:@"clock"] || 
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

// 缩放计算 (SB 特权隔离)
static CGFloat getScaledSize(CGFloat originalSize) {
    if (originalSize <= 0) return originalSize;
    // 【核心修复】SpringBoard 下绝对禁止缩放！防止日历图标 Date 文字越界导致 CGDataProvider 崩溃
    if (g_isSpringBoard) return originalSize;
    return originalSize * g_fontSizeScale;
}

// ================= [UIFont 核心 Hook 层 (绝对防御版)] =================
// 每一个 Hook 必须包含 ret ? ret : %orig 的防 nil 兜底逻辑！

%hook UIFont

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    if (!g_enabled || shouldBypassFont(fontName, fontSize)) return %orig;
    
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize));
    return ret ? ret : %orig;
}

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize traits:(int)traits {
    if (!g_enabled || shouldBypassFont(fontName, fontSize)) return %orig;
    
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize), traits);
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && fontSize >= 80.0) return %orig;
    
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(fontSize)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight design:(id)design {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && fontSize >= 80.0) return %orig;
    
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(fontSize)];
    return ret ? ret : %orig;
}

// [核心: iOS 16+ 适配]
+ (id)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight width:(CGFloat)width {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && fontSize >= 80.0) return %orig;
    
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(fontSize)];
    return ret ? ret : %orig;
}

// [核心: iOS 16+ 私有 API 拦截]
+ (id)_systemFontOfSize:(double)fontSize width:(id)width traits:(int)traits {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && fontSize >= 80.0) return %orig;
    
    id ret = [self fontWithName:g_customFontName size:getScaledSize(fontSize)];
    return ret ? ret : %orig;
}

+ (id)boldSystemFontOfSize:(CGFloat)fontSize {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && fontSize >= 80.0) return %orig;
    
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(fontSize)];
    return ret ? ret : %orig;
}

+ (id)italicSystemFontOfSize:(CGFloat)fontSize {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && fontSize >= 80.0) return %orig;
    
    id ret = [self fontWithName:g_customFontName size:getScaledSize(fontSize)];
    return ret ? ret : %orig;
}

// ================= [修复: Descriptor 拦截强化] =================
+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    if (!g_enabled || !descriptor) return %orig;
    
    NSString *reqName = descriptor.fontAttributes[@"UIFontDescriptorNameAttribute"] 
                     ?: descriptor.fontAttributes[@"NSFontNameAttribute"];
    
    CGFloat targetSize = (size > 0) ? size : descriptor.pointSize;
    if (reqName && shouldBypassFont(reqName, targetSize)) return %orig;
    
    BOOL wantBold = (descriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *targetFont = (wantBold && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    
    if (!targetFont) return %orig;
    
    UIFontDescriptor *newDesc = [UIFontDescriptor fontDescriptorWithName:targetFont size:getScaledSize(targetSize)];
    if (descriptor.symbolicTraits) {
        newDesc = [newDesc fontDescriptorWithSymbolicTraits:descriptor.symbolicTraits];
    }
    
    id ret = %orig(newDesc, 0);
    return ret ? ret : %orig;
}

// ================= [修复: Dynamic Type (preferred) 动态类型全家桶] =================
+ (id)preferredFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    if (!g_enabled) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:traitCollection];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)ib_preferredFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)defaultFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)_preferredFontForTextStyle:(id)style weight:(double)weight {
    if (!g_enabled) return %orig;
    UIFont *origFont = %orig;
    if (!origFont) return origFont;
    if (g_isSpringBoard && origFont.pointSize >= 80.0) return origFont;
    
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design weight:(double)weight {
    if (!g_enabled) return %orig;
    UIFont *origFont = %orig;
    if (!origFont) return origFont;
    if (g_isSpringBoard && origFont.pointSize >= 80.0) return origFont;
    
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

// ================= [修复: 等宽字体 (Monospaced)] =================
+ (id)monospacedDigitSystemFontOfSize:(double)size weight:(double)weight {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && size >= 80.0) return %orig;
    
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)monospacedSystemFontOfSize:(double)size weight:(double)weight {
    if (!g_enabled) return %orig;
    if (g_isSpringBoard && size >= 80.0) return %orig;
    
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

// ================= [修复: Storyboard / XIB 归档反序列化] =================
- (id)initWithCoder:(NSCoder *)coder {
    UIFont *font = %orig;
    if (!g_enabled || !font) return font;
    
    BOOL wantBold = (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *target = (wantBold && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    
    if (!target || shouldBypassFont(font.fontName, font.pointSize)) return font;
    
    id ret = [UIFont fontWithName:target size:getScaledSize(font.pointSize)];
    return ret ? ret : font;
}

%end


// ================= [初始化与内存注册] =================
%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    g_isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
    
    // 黑名单与极高危进程过滤
    NSArray *hardcodedBlacklist = @[
        @"com.apple.calculator", // 缩放 Bug
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
