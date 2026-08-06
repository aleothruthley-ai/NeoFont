#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ================= [私有 API 声明] =================
@interface UIFont (NeoFontPrivate)
+ (void)_evictAllItemsFromFontAndFontDescriptorCaches;
- (BOOL)isSystemFont;
@end

// ================= [全局配置变量] =================
static BOOL g_enabled = YES;
static NSString *g_customFontName = nil;
static NSString *g_customBoldFontName = nil;
static CGFloat g_fontSizeScale = 1.0;
static NSArray *g_blacklist = nil;
static BOOL g_isSpringBoard = NO;

// ================= [危险队列判断] =================
static BOOL isDangerousIconQueue() {
    if (!g_isSpringBoard) return NO;
    
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (!label) return NO;
    
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
    if (!fontName || fontName.length == 0) return NO;
    
    if ([fontName isEqualToString:g_customFontName] || [fontName isEqualToString:g_customBoldFontName]) return YES;
    
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"icon"] || 
        [lower containsString:@"emoji"] || 
        [lower containsString:@"glyph"] || 
        [lower containsString:@"assets"] || 
        [lower containsString:@"fontawesome"] ||
        [lower containsString:@"camera"] ||
        [lower containsString:@"keycap"] ||
        [lower containsString:@"passcode"] ||
        [lower containsString:@"keyboard"]) { 
        return YES;
    }
    return NO;
}

static BOOL isBoldRequest(NSString *fontName, CGFloat weight) {
    if (weight >= 0.2) return YES;
    if (!fontName) return NO;
    NSString *lower = [fontName lowercaseString];
    if ([lower containsString:@"bold"] || [lower containsString:@"heavy"] || [lower containsString:@"black"] || [lower containsString:@"semibold"]) return YES;
    return NO;
}

static CGFloat getScaledSize(CGFloat originalSize) {
    if (originalSize <= 0) return originalSize;
    // SpringBoard 强制 1.0 保证文件夹不卡
    if (g_isSpringBoard) return originalSize;
    return originalSize * g_fontSizeScale;
}

// ================= [核心转换器] =================
static UIFontDescriptor* getReplacedDescriptor(UIFontDescriptor *origDesc) {
    if (!origDesc) return nil;
    NSString *reqName = origDesc.fontAttributes[@"UIFontDescriptorNameAttribute"] ?: origDesc.fontAttributes[@"NSFontNameAttribute"];

    if (reqName && shouldBypassFont(reqName)) return origDesc;

    BOOL wantBold = (origDesc.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *targetFont = (wantBold && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return origDesc;

    UIFontDescriptor *newDesc = [UIFontDescriptor fontDescriptorWithName:targetFont size:origDesc.pointSize];
    if (origDesc.symbolicTraits) {
        UIFontDescriptor *withTraits = [newDesc fontDescriptorWithSymbolicTraits:origDesc.symbolicTraits];
        if (withTraits) newDesc = withTraits;
    }
    return newDesc ?: origDesc;
}

static UIFont *replaceFontIfNeeded(UIFont *origFont) {
    if (!g_enabled || !origFont) return origFont;
    
    // 只替换系统字体，避免破坏第三方/自定义字体和富文本
    if ([origFont respondsToSelector:@selector(isSystemFont)] && ![origFont isSystemFont]) {
        // 额外检查常见系统字体前缀
        NSString *name = origFont.fontName ?: @"";
        if (![name hasPrefix:@"."] && 
            ![name hasPrefix:@"SF"] && 
            ![name hasPrefix:@"Helvetica"] && 
            ![name hasPrefix:@"UICTFont"]) {
            return origFont;
        }
    }
    
    if (shouldBypassFont(origFont.fontName)) return origFont;
    
    BOOL wantBold = (origFont.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *target = (wantBold && g_customBoldFontName) ? g_customBoldFontName : g_customFontName;
    if (!target) return origFont;
    
    UIFont *newFont = [UIFont fontWithName:target size:getScaledSize(origFont.pointSize)];
    return newFont ?: origFont;
}

// ================= [UIFontDescriptor 兜底] =================
%hook UIFontDescriptor
- (id)fontDescriptorWithSymbolicTraits:(unsigned int)traits {
    id orig = %orig;
    if (!orig && g_enabled && !isDangerousIconQueue()) {
        NSString *target = (traits & UIFontDescriptorTraitBold) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
        if (target) {
            return [UIFontDescriptor fontDescriptorWithName:target size:self.pointSize];
        }
    }
    return orig;
}
%end


// ================= [UIFont 地毯式 Hook] =================
%hook UIFont

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

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    if (!g_enabled || isDangerousIconQueue() || !descriptor) return %orig;
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    CGFloat targetSize = (size > 0) ? size : descriptor.pointSize;
    newDesc = [newDesc fontDescriptorWithSize:getScaledSize(targetSize)];
    id ret = %orig(newDesc, 0);
    return ret ? ret : %orig;
}

+ (id)_fontWithDescriptor:(id)descriptor size:(double)size textStyleForScaling:(id)scaling pointSizeForScaling:(double)pointScaling maximumPointSizeAfterScaling:(double)maxScaling forIB:(BOOL)ib legibilityWeight:(long long)weight {
    if (!g_enabled || isDangerousIconQueue() || !descriptor) return %orig;
    UIFontDescriptor *newDesc = getReplacedDescriptor(descriptor);
    id ret = %orig(newDesc, getScaledSize(size), scaling, pointScaling, maxScaling, ib, weight);
    return ret ? ret : %orig;
}

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

// preferred 全家桶
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
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style addingSymbolicTraits:(unsigned int)traits {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style addingSymbolicTraits:(unsigned int)traits design:(id)design weight:(double)weight {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design variant:(long long)variant {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design variant:(long long)variant compatibleWithTraitCollection:(id)collection {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design variant:(long long)variant maximumContentSizeCategory:(id)category compatibleWithTraitCollection:(id)collection {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design variant:(long long)variant maximumContentSizeCategory:(id)category compatibleWithTraitCollection:(id)collection pointSize:(double)size pointSizeForScaling:(double)scaling {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style design:(id)design weight:(id)weight symbolicTraits:(unsigned int)traits maximumContentSizeCategory:(id)category compatibleWithTraitCollection:(id)collection pointSize:(double)size pointSizeForScaling:(double)scaling {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style maximumContentSizeCategory:(id)category {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style maximumContentSizeCategory:(id)category compatibleWithTraitCollection:(id)collection {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style maximumPointSize:(double)size compatibleWithTraitCollection:(id)collection {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style variant:(long long)variant {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

+ (id)_preferredFontForTextStyle:(id)style variant:(long long)variant maximumContentSizeCategory:(id)category {
    if (!g_enabled || isDangerousIconQueue()) return %orig;
    return replaceFontIfNeeded(%orig);
}

- (id)initWithName:(NSString *)name size:(double)size {
    if (!g_enabled || isDangerousIconQueue() || shouldBypassFont(name)) return %orig;
    NSString *targetFont = isBoldRequest(name, 0) && g_customBoldFontName ? g_customBoldFontName : g_customFontName;
    if (!targetFont) return %orig;
    id ret = %orig(targetFont, getScaledSize(size));
    return ret ? ret : %orig;
}

- (id)initWithCoder:(NSCoder *)coder {
    return replaceFontIfNeeded(%orig);
}

- (id)fontWithSize:(double)size {
    return replaceFontIfNeeded(%orig);
}

%end


// ================= 【最终拦截】 =================
%hook UILabel
- (void)setFont:(UIFont *)font {
    if (!g_enabled) {
        %orig;
        return;
    }
    %orig(replaceFontIfNeeded(font));
}
%end

%hook UITextField
- (void)setFont:(UIFont *)font {
    if (!g_enabled) {
        %orig;
        return;
    }
    %orig(replaceFontIfNeeded(font));
}
%end

%hook UITextView
- (void)setFont:(UIFont *)font {
    if (!g_enabled) {
        %orig;
        return;
    }
    %orig(replaceFontIfNeeded(font));
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
            CFRelease(error);
        }
    }
    
    if ([UIFont respondsToSelector:@selector(_evictAllItemsFromFontAndFontDescriptorCaches)]) {
        [UIFont _evictAllItemsFromFontAndFontDescriptorCaches];
    }
}

// ================= [热更新] =================
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

// ================= [初始化] =================
%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    g_isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
    
    // 关键：把 Spotlight 加入硬黑名单，彻底解决下拉搜索崩溃
    NSArray *hardcodedBlacklist = @[
        @"com.apple.calculator", 
        @"com.apple.photos.VideoConversionService",
        @"com.apple.springboard.SBRendererService",
        @"com.apple.Search.Framework",
        @"com.apple.Spotlight"          // ← 新增，解决搜索进程重启
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

    registerCustomFonts();
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    reloadPrefsAndFonts,
                                    CFSTR("com.iosdump.neofont.prefsChanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    
    %init;
}
