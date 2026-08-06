#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

@interface UIFont (NeoFontPrivate)
+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize traits:(int)traits;
@end

// ================= [全局配置变量] =================
static BOOL g_enabled = YES;
static NSString *g_customFontName = nil;
static NSString *g_customBoldFontName = nil;
static CGFloat g_fontSizeScale = 1.0;
static NSArray *g_blacklist = nil;
static BOOL g_isSpringBoard = NO;


// ================= [终极防死锁：RAII 深度计数锁] =================
// 线程局部深度计数器
static __thread int g_hookDepth = 0;

// 自动清理函数，当离开作用域时必然执行，杜绝死锁！
static inline void decrement_depth(int *x) {
    g_hookDepth--;
}

// 核心宏定义：在函数头部调用，允许最多3层系统内部嵌套，防死循环
#define NEO_LOCK \
    if (!g_enabled || isDangerousIconQueue()) return %orig; \
    if (g_hookDepth >= 3) return %orig; \
    g_hookDepth++; \
    int __attribute__((cleanup(decrement_depth))) _cleaner = 0; \
    (void)_cleaner;

#define NEO_LOCK_BYPASS(fname) \
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(fname)) return %orig; \
    if (g_hookDepth >= 3) return %orig; \
    g_hookDepth++; \
    int __attribute__((cleanup(decrement_depth))) _cleaner = 0; \
    (void)_cleaner;


// ================= [高精度防崩：精准定位日历图标后台缓存溢出] =================
static BOOL isDangerousIconQueue() {
    if (!g_isSpringBoard) return NO;
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (!label) return NO;
    if (strstr(label, "SBHIconImageCache") || strstr(label, "IconPrecache") || strstr(label, "IconView")) {
        return YES;
    }
    return NO;
}

// ================= [安全过滤逻辑] =================
static BOOL shouldBypassFont(NSString *fontName) {
    if (!fontName) return NO; 
    if ([fontName isEqualToString:g_customFontName] || [fontName isEqualToString:g_customBoldFontName]) return YES;
    
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"icon"] || 
        [lower containsString:@"emoji"] || 
        [lower containsString:@"glyph"] || 
        [lower containsString:@"assets"] || 
        [lower containsString:@"fontawesome"] ||
        [lower containsString:@"camera"]) { 
        return YES;
    }
    return NO;
}

static BOOL isBoldRequest(NSString *fontName, CGFloat weight) {
    if (weight >= 0.2) return YES;
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"bold"] || [lower containsString:@"heavy"] || [lower containsString:@"black"]) return YES;
    return NO;
}

static CGFloat getScaledSize(CGFloat originalSize) {
    if (originalSize <= 0) return originalSize;
    return originalSize * g_fontSizeScale;
}

static UIFontDescriptor* getReplacedDescriptor(UIFontDescriptor *origDesc) {
    if (!origDesc) return nil;
    NSString *reqName = origDesc.fontAttributes[@"UIFontDescriptorNameAttribute"] ?: origDesc.fontAttributes[@"NSFontNameAttribute"];

    if (reqName && shouldBypassFont(reqName)) return origDesc;

    BOOL wantBold = (origDesc.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *targetFont = (wantBold && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return origDesc;

    UIFontDescriptor *newDesc = [UIFontDescriptor fontDescriptorWithName:targetFont size:origDesc.pointSize];
    if (origDesc.symbolicTraits) {
        newDesc = [newDesc fontDescriptorWithSymbolicTraits:origDesc.symbolicTraits];
    }
    return newDesc;
}

// ================= [UIFontDescriptor Hook] =================
%hook UIFontDescriptor
- (id)fontDescriptorWithSymbolicTraits:(unsigned int)traits {
    NEO_LOCK
    id orig = %orig;
    if (!orig) {
        NSString *target = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
        return [UIFontDescriptor fontDescriptorWithName:target size:self.pointSize];
    }
    return orig;
}
%end


// ================= [UIFont 地毯式 Hook 层] =================
%hook UIFont

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    NEO_LOCK_BYPASS(fontName)
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize));
    return ret ? ret : %orig;
}

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize traits:(int)traits {
    NEO_LOCK_BYPASS(fontName)
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize), traits);
    return ret ? ret : %orig;
}

+ (id)_fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    NEO_LOCK_BYPASS(fontName)
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize));
    return ret ? ret : %orig;
}

+ (id)fontWithFamilyName:(NSString *)name traits:(int)traits size:(double)size {
    NEO_LOCK_BYPASS(name)
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    if (!descriptor) return %orig;
    NEO_LOCK
    
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    CGFloat targetSize = (size > 0) ? size : descriptor.pointSize;
    newDesc = [newDesc fontDescriptorWithSize:getScaledSize(targetSize)];
    
    id ret = %orig(newDesc, 0);
    return ret ? ret : %orig;
}

+ (id)_fontWithDescriptor:(id)descriptor size:(double)size textStyleForScaling:(id)scaling pointSizeForScaling:(double)pointScaling maximumPointSizeAfterScaling:(double)maxScaling forIB:(BOOL)ib legibilityWeight:(long long)weight {
    if (!descriptor) return %orig;
    NEO_LOCK
    
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    id ret = %orig(newDesc, getScaledSize(size), scaling, pointScaling, maxScaling, ib, weight);
    return ret ? ret : %orig;
}

- (id)initWithName:(NSString *)name size:(double)size {
    NEO_LOCK_BYPASS(name)
    NSString *targetFont = isBoldRequest(name, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(size));
    return ret ? ret : %orig;
}

// ----------------包装层----------------
+ (id)systemFontOfSize:(CGFloat)size {
    NEO_LOCK
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(double)size traits:(int)traits {
    NEO_LOCK
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size) traits:traits];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    NEO_LOCK
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight design:(id)design {
    NEO_LOCK
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight width:(CGFloat)width {
    NEO_LOCK
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)_systemFontsOfSize:(double)size traits:(int)traits {
    NEO_LOCK
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size) traits:traits];
    return ret ? ret : %orig;
}

+ (id)_systemFontOfSize:(double)size width:(id)width traits:(int)traits {
    NEO_LOCK
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size) traits:traits];
    return ret ? ret : %orig;
}

+ (id)boldSystemFontOfSize:(CGFloat)size {
    NEO_LOCK
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)italicSystemFontOfSize:(CGFloat)size {
    NEO_LOCK
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)monospacedDigitSystemFontOfSize:(double)size weight:(double)weight {
    NEO_LOCK
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)monospacedSystemFontOfSize:(double)size weight:(double)weight {
    NEO_LOCK
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)userFontOfSize:(double)size {
    NEO_LOCK
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)_lightSystemFontOfSize:(double)size {
    NEO_LOCK
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_thinSystemFontOfSize:(double)size {
    NEO_LOCK
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_ultraLightSystemFontOfSize:(double)size {
    NEO_LOCK
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_opticalSystemFontOfSize:(double)size {
    NEO_LOCK
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_opticalBoldSystemFontOfSize:(double)size {
    NEO_LOCK
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)preferredFontForTextStyle:(UIFontTextStyle)style {
    NEO_LOCK
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    NEO_LOCK
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:traitCollection];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)ib_preferredFontForTextStyle:(UIFontTextStyle)style {
    NEO_LOCK
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)defaultFontForTextStyle:(UIFontTextStyle)style {
    NEO_LOCK
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)_preferredFontForTextStyle:(id)style weight:(double)weight {
    NEO_LOCK
    UIFont *origFont = %orig;
    if (!origFont) return origFont;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design weight:(double)weight {
    NEO_LOCK
    UIFont *origFont = %orig;
    if (!origFont) return origFont;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

- (id)initWithCoder:(NSCoder *)coder {
    NEO_LOCK
    UIFont *font = %orig;
    if (!font) return font;
    
    BOOL wantBold = (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *target = (wantBold && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!target || shouldBypassFont(font.fontName)) return font;
    
    id ret = [UIFont fontWithName:target size:getScaledSize(font.pointSize)];
    return ret ? ret : font;
}

%end

// ================= [初始化与内存注册] =================
%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    g_isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
    
    NSArray *hardcodedBlacklist = @[
        @"com.apple.calculator", 
        @"com.apple.photos.VideoConversionService",
        @"com.apple.springboard.SBRendererService",
        @"com.apple.Search.Framework"
    ];
    if ([hardcodedBlacklist containsObject:bundleID]) return;

    NSString *prefPath = jbroot(@"/var/mobile/Library/Preferences/com.iosdump.neofont.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    
    g_enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    if (!g_enabled) return;

    g_blacklist = prefs[@"Blacklist"] ?: @[];
    if ([g_blacklist containsObject:bundleID]) return;

    g_customFontName = prefs[@"CustomFont"];
    g_customBoldFontName = prefs[@"CustomBoldFont"];
    g_fontSizeScale = prefs[@"FontScale"] ? [prefs[@"FontScale"] doubleValue] : 1.0;
    
    if (!g_customFontName || g_customFontName.length == 0) return;

    NSString *fontDir = jbroot(@"/var/mobile/Library/NeoFont");
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:fontDir]) {
        NSArray *files = [fm contentsOfDirectoryAtPath:fontDir error:nil];
        for (NSString *file in files) {
            if ([file hasSuffix:@".ttf"] || [file hasSuffix:@".otf"] || [file hasSuffix:@".ttc"]) {
                NSString *fullPath = [fontDir stringByAppendingPathComponent:file];
                NSURL *fontURL = [NSURL fileURLWithPath:fullPath];
                
                CFErrorRef error;
                CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, nil);
                CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, &error);
            }
        }
    }
    
    %init;
}
