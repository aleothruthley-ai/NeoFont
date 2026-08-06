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

// ================= [高精度防崩：大幅扩展危险队列，解决文件夹卡住] =================
static BOOL isDangerousIconQueue() {
    if (!g_isSpringBoard) return NO;
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (!label) return NO;
    
    // 覆盖 Icon 缓存、Folder 打开、Layout、Label 计算等所有高风险路径
    if (strstr(label, "SBHIconImageCache") ||
        strstr(label, "IconPrecache") ||
        strstr(label, "IconImage") ||
        strstr(label, "IconLabel") ||
        strstr(label, "SBIcon") ||
        strstr(label, "Folder") ||
        strstr(label, "Layout") ||
        strstr(label, "SBH") ||
        strstr(label, "IconManager") ||
        strstr(label, "HomeScreen") ||
        strstr(label, "IconList") ||
        strstr(label, "PageManagement")) {
        return YES;
    }
    return NO;
}

// ================= [安全过滤逻辑] =================
static BOOL shouldBypassFont(NSString *fontName) {
    if (!fontName || fontName.length == 0) return NO; // 名字为空通常是系统动态字体，不能 Bypass！必须拦截！
    
    if ([fontName isEqualToString:g_customFontName] || [fontName isEqualToString:g_customBoldFontName]) return YES;
    
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"icon"] || 
        [lower containsString:@"emoji"] || 
        [lower containsString:@"glyph"] || 
        [lower containsString:@"assets"] || 
        [lower containsString:@"fontawesome"] ||
        [lower containsString:@"camera"] ||
        [lower containsString:@"keycap"] ||      // 锁屏密码键盘相关
        [lower containsString:@"passcode"] ||
        [lower containsString:@"keyboard"]) { 
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
    // SpringBoard 下强制 scale=1.0 可进一步降低 metrics 冲击（可选，已注释）
    // if (g_isSpringBoard) return originalSize;
    return originalSize * g_fontSizeScale;
}

// ================= [核心通用转换器] =================
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
    return newDesc ?: origDesc;
}

// ================= [修复：UIFontDescriptor 符号丢失问题] =================
%hook UIFontDescriptor
- (id)fontDescriptorWithSymbolicTraits:(unsigned int)traits {
    id orig = %orig;
    // 很多时候系统尝试请求不存在的 Traits 时会返回 nil，导致后续闪退，此处强制兜底
    if (!orig && g_enabled && !isDangerousIconQueue()) {
        NSString *target = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
        if (target) {
            return [UIFontDescriptor fontDescriptorWithName:target size:self.pointSize];
        }
    }
    return orig;
}
%end


// ================= [UIFont 地毯式 Hook 层] =================
%hook UIFont

// 1. 公共构建方法
+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(fontName)) return %orig;
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = %orig(targetFont, getScaledSize(fontSize));
    return ret ? ret : %orig;
}

+ (id)fontWithName:(NSString *)fontName size:(CGFloat)fontSize traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(fontName)) return %orig;
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = %orig(targetFont, getScaledSize(fontSize), traits);
    return ret ? ret : %orig;
}

+ (id)_fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(fontName)) return %orig;
    NSString *targetFont = isBoldRequest(fontName, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = %orig(targetFont, getScaledSize(fontSize));
    return ret ? ret : %orig;
}

+ (id)fontWithFamilyName:(NSString *)name traits:(int)traits size:(double)size {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(name)) return %orig;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

// 2. 描述符与 SwiftUI/Widget 核心私有初始化
+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue() || !descriptor) return %orig;
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    CGFloat targetSize = (size > 0) ? size : descriptor.pointSize;
    newDesc = [newDesc fontDescriptorWithSize:getScaledSize(targetSize)];
    id ret = %orig(newDesc, 0);
    return ret ? ret : %orig;
}

// 【关键突破】：拦截 SwiftUI 和 Widgets 使用的最底层 7 参数初始化方法！
+ (id)_fontWithDescriptor:(id)descriptor size:(double)size textStyleForScaling:(id)scaling pointSizeForScaling:(double)pointScaling maximumPointSizeAfterScaling:(double)maxScaling forIB:(BOOL)ib legibilityWeight:(long long)weight {
    if (!g_enabled || isDangerousIconQueue() || !descriptor) return %orig;
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    id ret = %orig(newDesc, getScaledSize(size), scaling, pointScaling, maxScaling, ib, weight);
    return ret ? ret : %orig;
}

// 3. System Font 系列 (包括视频时间与各种变体)
+ (id)systemFontOfSize:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (!g_customFontName) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(double)size traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight design:(id)design {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)systemFontOfSize:(CGFloat)size weight:(CGFloat)weight width:(CGFloat)width {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)_systemFontsOfSize:(double)size traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)_systemFontOfSize:(double)size width:(id)width traits:(int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)boldSystemFontOfSize:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)italicSystemFontOfSize:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (!g_customFontName) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

// 【关键突破】：视频时间与等宽数字拦截
+ (id)monospacedDigitSystemFontOfSize:(double)size weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)monospacedSystemFontOfSize:(double)size weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

+ (id)userFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (!g_customFontName) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}

// 【关键突破】：私有光学术型字体全拦截
+ (id)_lightSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (!g_customFontName) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_thinSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (!g_customFontName) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_ultraLightSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (!g_customFontName) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_opticalSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    if (!g_customFontName) return %orig;
    id ret = [self fontWithName:g_customFontName size:getScaledSize(size)];
    return ret ? ret : %orig;
}
+ (id)_opticalBoldSystemFontOfSize:(double)size {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    NSString *targetFont = g_customBoldFontName ?: g_customFontName;
    if (!targetFont) return %orig;
    id ret = [self fontWithName:targetFont size:getScaledSize(size)];
    return ret ? ret : %orig;
}

// 4. Dynamic Type (preferred) 全家桶
+ (id)preferredFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:traitCollection];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)ib_preferredFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)defaultFontForTextStyle:(UIFontTextStyle)style {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    UIFontDescriptor *desc = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    id ret = [self fontWithDescriptor:desc size:0];
    return ret ? ret : %orig;
}

+ (id)_preferredFontForTextStyle:(id)style weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    UIFont *origFont = %orig;
    if (!origFont) return origFont;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return origFont;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    UIFont *origFont = %orig;
    if (!origFont) return origFont;
    NSString *targetFont = (weight >= 0.2 && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return origFont;
    id ret = [self fontWithName:targetFont size:getScaledSize(origFont.pointSize)];
    return ret ? ret : origFont;
}

// 5. 实例初始化与归档反序列化
- (id)initWithName:(NSString *)name size:(double)size {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(name)) return %orig;
    NSString *targetFont = isBoldRequest(name, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = %orig(targetFont, getScaledSize(size));
    return ret ? ret : %orig;
}

- (id)initWithCoder:(NSCoder *)coder {
    UIFont *font = %orig;
    if (!g_enabled || isDangerousIconQueue() || !font) return font;
    
    BOOL wantBold = (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *target = (wantBold && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    
    if (!target || shouldBypassFont(font.fontName)) return font;
    
    id ret = [UIFont fontWithName:target size:getScaledSize(font.pointSize)];
    return ret ? ret : font;
}

%end


// ================= [强化字体注册 + 强制清缓存] =================
static void registerCustomFonts() {
    NSString *fontDir = jbroot(@"/var/mobile/Library/NeoFont");
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:fontDir]) return;
    
    NSArray *files = [fm contentsOfDirectoryAtPath:fontDir error:nil];
    for (NSString *file in files) {
        NSString *ext = file.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"ttf"] && ![ext isEqualToString:@"otf"] && ![ext isEqualToString:@"ttc"]) continue;
        
        NSString *fullPath = [fontDir stringByAppendingPathComponent:file];
        NSURL *fontURL = [NSURL fileURLWithPath:fullPath];
        
        CFErrorRef error = NULL;
        CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, NULL);
        bool success = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, &error);
        if (!success && error) {
            // 可在此写日志调试
            CFRelease(error);
        }
    }
    
    // 强制清理所有字体缓存（解决锁屏键盘有时不生效的关键）
    if ([UIFont respondsToSelector:@selector(_evictAllItemsFromFontAndFontDescriptorCaches)]) {
        [UIFont _evictAllItemsFromFontAndFontDescriptorCaches];
    }
}

// ================= [热更新支持：prefs 改变立即生效 + 小组件强制刷新] =================
static void reloadPrefsAndFonts(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *prefPath = jbroot(@"/var/mobile/Library/Preferences/com.iosdump.neofont.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    if (!prefs) return;
    
    g_enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;
    g_customFontName = prefs[@"CustomFont"];
    g_customBoldFontName = prefs[@"CustomBoldFont"];
    g_fontSizeScale = prefs[@"FontScale"] ? [prefs[@"FontScale"] doubleValue] : 1.0;
    g_blacklist = prefs[@"Blacklist"] ?: @[];
    
    if (!g_enabled || !g_customFontName || g_customFontName.length == 0) return;
    
    registerCustomFonts();
    
    // 强制刷新所有小组件（仅在 SpringBoard 执行）
    if (g_isSpringBoard) {
        Class WC = NSClassFromString(@"WidgetCenter");
        if (WC) {
            id center = [WC performSelector:@selector(sharedCenter)];
            if (center && [center respondsToSelector:@selector(reloadAllTimelines)]) {
                [center performSelector:@selector(reloadAllTimelines)];
            }
        }
    }
}

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

    // 使用强化注册
    registerCustomFonts();
    
    // 注册热更新通知（设置面板改完后 post 这个 name 即可马上生效）
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    reloadPrefsAndFonts,
                                    CFSTR("com.iosdump.neofont.prefsChanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    
    %init;
}
