#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ================= [私有方法声明：解决编译报错] =================
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

// 【核心防护】：C级线程局部变量。只在核心 %orig 调用时加锁，打破 CoreText 死循环！
static __thread BOOL isHooking = NO;

// ================= [终极防崩：只拦截后台缓存队列，绝不误杀主线程可视 UI！] =================
static BOOL isDangerousIconQueue() {
    if (!g_isSpringBoard) return NO;
    
    // 【核心精髓】：所有能在屏幕上看到的锁屏、小组件、UI 都是在主线程更新的。
    // 我们直接放行主线程，不仅能 100% 保证覆盖率，还能避开所有后台并发的图标缓存崩溃！
    if ([NSThread isMainThread]) return NO;
    
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (!label) return NO;
    
    // 拦截导致内存溢出和卡死的后台图片生成队列
    if (strstr(label, "Icon") ||
        strstr(label, "SBH") ||
        strstr(label, "Folder") ||
        strstr(label, "Precache") ||
        strstr(label, "ImageCache") ||
        strstr(label, "LabelImage") ||
        strstr(label, "com.apple.SpringBoard")) {
        return YES;
    }
    return NO;
}

// ================= [安全过滤逻辑] =================
static BOOL shouldBypassFont(NSString *fontName) {
    if (!fontName) return NO; 
    
    // 删除了上一个版本的 [fontName hasPrefix:@"."] 限制！
    // 因为苹果的 .SFUI 等核心 UI 字体必须被替换！
    
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

// ================= [核心通用转换器] =================
static UIFontDescriptor* getReplacedDescriptor(UIFontDescriptor *origDesc) {
    if (!origDesc || isDangerousIconQueue()) return origDesc;
    
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

%hook UIFontDescriptor
- (id)fontDescriptorWithSymbolicTraits:(unsigned int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    
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

// ---------------------------------------------------------
// 核心源方法区 (内部调用 %orig，必须加 isHooking 防死锁)
// ---------------------------------------------------------
+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(fontName)) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize));
    isHooking = NO;
    
    return ret ? ret : %orig;
}

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(fontName)) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize), traits);
    isHooking = NO;
    
    return ret ? ret : %orig;
}

+ (id)_fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(fontName)) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(fontSize));
    isHooking = NO;
    
    return ret ? ret : %orig;
}

+ (id)fontWithFamilyName:(NSString *)name traits:(int)traits size:(double)size {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(name)) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    isHooking = NO;
    
    return ret ? ret : %orig;
}

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue() || !descriptor) return %orig;
    if (isHooking) return %orig;
    
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    CGFloat targetSize = (size > 0) ? size : descriptor.pointSize;
    newDesc = [newDesc fontDescriptorWithSize:getScaledSize(targetSize)];
    
    isHooking = YES;
    id ret = %orig(newDesc, 0);
    isHooking = NO;
    
    return ret ? ret : %orig;
}

+ (id)_fontWithDescriptor:(id)descriptor size:(double)size textStyleForScaling:(id)scaling pointSizeForScaling:(double)pointScaling maximumPointSizeAfterScaling:(double)maxScaling forIB:(BOOL)ib legibilityWeight:(long long)weight {
    if (!g_enabled || isDangerousIconQueue() || !descriptor) return %orig;
    if (isHooking) return %orig;
    
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    
    isHooking = YES;
    id ret = %orig(newDesc, getScaledSize(size), scaling, pointScaling, maxScaling, ib, weight);
    isHooking = NO;
    
    return ret ? ret : %orig;
}

- (id)initWithName:(NSString *)name size:(double)size {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(name)) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    NSString *targetFont = isBoldRequest(name, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = %orig(targetFont, getScaledSize(size));
    isHooking = NO;
    
    return ret ? ret : %orig;
}


// ---------------------------------------------------------
// 包装重定向区 (这些负责把请求重定向给上面的核心方法，绝不加锁)
// ---------------------------------------------------------
+ (id)systemFontOfSize:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(double)size traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size) traits:traits];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight design:(id)design {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight width:(CGFloat)width {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)_systemFontsOfSize:(double)size traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size) traits:traits];
    return ret ? ret : %orig;
}

+ (id)_systemFontOfSize:(double)size width:(id)width traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size) traits:traits];
    return ret ? ret : %orig;
}

+ (id)boldSystemFontOfSize:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)italicSystemFontOfSize:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)monospacedDigitSystemFontOfSize:(double)size weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)monospacedSystemFontOfSize:(double)size weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)userFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)_lightSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_thinSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_ultraLightSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_opticalSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_opticalBoldSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)preferredFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:traitCollection];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)ib_preferredFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)defaultFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)_preferredFontForTextStyle:(id)style weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    UIFont *origFont = %orig;
    isHooking = NO;
    
    if (!origFont) return origFont;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    UIFont *origFont = %orig;
    isHooking = NO;
    
    if (!origFont) return origFont;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

- (id)initWithCoder:(NSCoder *)coder {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (isHooking) return %orig;
    
    isHooking = YES;
    UIFont *font = %orig;
    isHooking = NO;
    
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
    
    // [修复] 移除了 g_fontSizeScale = 1.0; 的强制重置，恢复用户设置的缩放体验！
    
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
