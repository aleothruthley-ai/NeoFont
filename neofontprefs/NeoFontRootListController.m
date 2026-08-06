#import "NeoFontRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreText/CoreText.h>
#import <spawn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

extern char **environ;

@interface PSSpecifier (NeoFontPrivate)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

static NSString * GetFontDirPath() {
    NSString *path = jbroot(@"/var/mobile/Library/NeoFont");
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
    }
    return path;
}

@interface NeoFontRootListController () <UIDocumentPickerDelegate>
@end

@implementation NeoFontRootListController

- (UITableViewStyle)tableViewStyle {
    if (@available(iOS 13.0, *)) return UITableViewStyleInsetGrouped;
    return UITableViewStyleGrouped;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell respondsToSelector:@selector(specifier)]) {
        PSSpecifier *spec = [cell performSelector:@selector(specifier)];
        if (spec && spec.cellType == PSGroupCell) return;
    }

    NSInteger numberOfRows = [tableView numberOfRowsInSection:indexPath.section];
    BOOL isFirst = (indexPath.row == 0);
    BOOL isLast = (indexPath.row == numberOfRows - 1);

    CGFloat radius = 25.0;
    CACornerMask mask = 0;

    if (isFirst && isLast) {
        mask = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    } else if (isFirst) {
        mask = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    } else if (isLast) {
        mask = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    } else {
        radius = 0; mask = 0;
    }

    cell.layer.borderWidth = 0.0;
    cell.layer.cornerRadius = radius;
    cell.layer.maskedCorners = mask;
    cell.layer.masksToBounds = YES;
    
    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *bg = cell.backgroundConfiguration;
        if (bg) {
            bg.cornerRadius = 25.0;
            bg.strokeWidth = 0.0;
            cell.backgroundConfiguration = bg;
        }
    }
    if (@available(iOS 13.0, *)) cell.layer.cornerCurve = kCACornerCurveContinuous;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
        
        NSMutableArray *fontNames = [NSMutableArray arrayWithObject:@"系统默认"];
        NSMutableArray *fontValues = [NSMutableArray arrayWithObject:@""];
        
        NSString *fontDir = GetFontDirPath();
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fontDir error:nil];
        
        for (NSString *file in files) {
            if ([file hasSuffix:@".ttf"] || [file hasSuffix:@".otf"] || [file hasSuffix:@".ttc"]) {
                NSURL *url = [NSURL fileURLWithPath:[fontDir stringByAppendingPathComponent:file]];
                NSArray *descriptors = (__bridge_transfer NSArray *)CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
                for (UIFontDescriptor *desc in descriptors) {
                    NSString *psName = desc.fontAttributes[@"NSFontNameAttribute"];
                    if (psName && ![fontValues containsObject:psName]) {
                        [fontNames addObject:[NSString stringWithFormat:@"%@ (%@)", psName, file]];
                        [fontValues addObject:psName];
                    }
                }
            }
        }
        
        for (PSSpecifier *spec in specs) {
            NSString *key = [spec propertyForKey:@"key"];
            if ([key isEqualToString:@"CustomFont"] || [key isEqualToString:@"CustomBoldFont"]) {
                [spec setValues:fontValues titles:fontNames];
            }
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.iosdump.neofont.prefsChanged"),
                                         NULL, NULL, true);
}

- (void)importFontAction {
    NSArray *types = @[@"public.font", @"public.truetype-ttf-font", @"public.opentype-font", @"public.zip-archive"];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destDir = GetFontDirPath();
    BOOL needReload = NO;
    
    for (NSURL *url in urls) {
        BOOL isScoped = [url startAccessingSecurityScopedResource];
        NSString *ext = [url.pathExtension lowercaseString];
        
        if ([ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"] || [ext isEqualToString:@"ttc"]) {
            NSString *destPath = [destDir stringByAppendingPathComponent:[url lastPathComponent]];
            [fm removeItemAtPath:destPath error:nil];
            if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:nil]) {
                needReload = YES;
            }
        }
        else if ([ext isEqualToString:@"zip"]) {
            NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
            
            NSString *tempZipPath = [tempDir stringByAppendingPathComponent:@"temp.zip"];
            if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tempZipPath] error:nil]) {
                
                pid_t pid;
                NSString *unzipPath = jbroot(@"/usr/bin/unzip");
                const char *argv[] = {"unzip", "-o", [tempZipPath UTF8String], "-d", [tempDir UTF8String], NULL};
                int status = posix_spawn(&pid, [unzipPath UTF8String], NULL, NULL, (char* const*)argv, environ);
                
                if (status == 0) {
                    waitpid(pid, &status, 0);
                    
                    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tempDir];
                    for (NSString *subPath in enumerator) {
                        NSString *subExt = [subPath.pathExtension lowercaseString];
                        if ([subExt isEqualToString:@"ttf"] || [subExt isEqualToString:@"otf"] || [subExt isEqualToString:@"ttc"]) {
                            NSString *fullSubPath = [tempDir stringByAppendingPathComponent:subPath];
                            NSString *finalDest = [destDir stringByAppendingPathComponent:[subPath lastPathComponent]];
                            
                            [fm removeItemAtPath:finalDest error:nil];
                            if ([fm moveItemAtPath:fullSubPath toPath:finalDest error:nil]) {
                                needReload = YES;
                            }
                        }
                    }
                }
            }
            [fm removeItemAtPath:tempDir error:nil];
        }
        
        if (isScoped) {
            [url stopAccessingSecurityScopedResource];
        }
    }
    
    if (needReload) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.iosdump.neofont.prefsChanged"),
                                             NULL, NULL, true);
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功" 
                                                                       message:@"字体已导入并热更新。大部分界面已立即生效，锁屏键盘/桌面文件夹建议注销一次彻底稳定。" 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self reloadSpecifiers];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)respringAction {
    pid_t pid;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *killallPath = jbroot(@"/usr/bin/killall");
    
    // 最全杀进程列表（确保字体缓存全部清掉）
    if ([fm fileExistsAtPath:killallPath]) {
        const char *procs[] = {
            "widgetkitd",
            "WidgetRenderer",
            "Spotlight",
            "InputUI",
            "Keyboard",
            "com.apple.Keyboard",
            "Search",
            "mediaserverd",
            "SpringBoard",
            NULL
        };
        for (int i = 0; procs[i]; i++) {
            const char *args[] = {"killall", "-9", procs[i], NULL};
            posix_spawn(&pid, [killallPath UTF8String], NULL, NULL, (char *const *)args, environ);
            waitpid(pid, NULL, 0);
        }
    }
    
    // 强制发一次热更新通知
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.iosdump.neofont.prefsChanged"),
                                         NULL, NULL, true);
    
    // 1. 优先 sbreload（最干净，有黑屏）
    NSString *sbreloadPath = jbroot(@"/usr/bin/sbreload");
    if ([fm fileExistsAtPath:sbreloadPath]) {
        const char *args[] = {"sbreload", NULL};
        posix_spawn(&pid, [sbreloadPath UTF8String], NULL, NULL, (char *const *)args, environ);
        return;
    }
    
    // 2. Fallback：kill backboardd
    if ([fm fileExistsAtPath:killallPath]) {
        const char *args[] = {"killall", "-9", "backboardd", NULL};
        posix_spawn(&pid, [killallPath UTF8String], NULL, NULL, (char *const *)args, environ);
        return;
    }
    
    // 3. 最终 Fallback：再杀一次 SpringBoard
    if ([fm fileExistsAtPath:killallPath]) {
        const char *args[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, [killallPath UTF8String], NULL, NULL, (char *const *)args, environ);
    }
}

@end
