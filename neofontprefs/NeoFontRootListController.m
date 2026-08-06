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

// [修复] 删除了未使用的 GetPrefPath 函数，避免被 -Werror 拦截报错

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

// 继承原生药丸圆角 UI
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
        
        // 动态读取已导入的字体，解析 PostScript Name 供用户选择
        NSMutableArray *fontNames = [NSMutableArray arrayWithObject:@"系统默认"];
        NSMutableArray *fontValues = [NSMutableArray arrayWithObject:@""];
        
        NSString *fontDir = GetFontDirPath();
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fontDir error:nil];
        
        for (NSString *file in files) {
            if ([file hasSuffix:@".ttf"] || [file hasSuffix:@".otf"] || [file hasSuffix:@".ttc"]) {
                NSURL *url = [NSURL fileURLWithPath:[fontDir stringByAppendingPathComponent:file]];
                // CoreText 解析真实字体名 (支持 TTC 内的多个 Face)
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
        
        // 动态注入选项到 List
        for (PSSpecifier *spec in specs) {
            NSString *key = [spec propertyForKey:@"key"];
            if ([key isEqualToString:@"CustomFont"] || [key isEqualToString:@"CustomBoldFont"]) {
                // 替换为底层的 Property 注入方法，避开 setValues:titles: 头文件缺失问题
                [spec setProperty:fontValues forKey:@"validValues"];
                [spec setProperty:fontNames forKey:@"validTitles"];
            }
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}

// ================= [文件导入核心逻辑 (支持 ZIP/TTF/OTF/TTC)] =================
- (void)importFontAction {
    NSArray *types = @[@"public.font", @"public.truetype-ttf-font", @"public.opentype-font", @"public.zip-archive"];
    
    // 使用 Clang 指令屏蔽 iOS 14.0+ 引入的 API 废弃报错，保持兼容性
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
        NSString *ext = [url.pathExtension lowercaseString];
        
        // ZIP 解压支持 (利用 iOS 底层 unzip 命令)
        if ([ext isEqualToString:@"zip"]) {
            NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
            
            pid_t pid;
            const char *argv[] = {"unzip", "-o", [[url path] UTF8String], "-d", [tempDir UTF8String], NULL};
            int status = posix_spawn(&pid, "/usr/bin/unzip", NULL, NULL, (char* const*)argv, environ);
            
            if (status == 0) {
                waitpid(pid, &status, 0);
                // 遍历解压出的目录寻找字体文件
                NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tempDir];
                for (NSString *subPath in enumerator) {
                    if ([subPath hasSuffix:@".ttf"] || [subPath hasSuffix:@".otf"] || [subPath hasSuffix:@".ttc"]) {
                        NSString *fullSubPath = [tempDir stringByAppendingPathComponent:subPath];
                        NSString *finalDest = [destDir stringByAppendingPathComponent:[subPath lastPathComponent]];
                        [fm removeItemAtPath:finalDest error:nil]; // 覆盖旧文件
                        [fm moveItemAtPath:fullSubPath toPath:finalDest error:nil];
                        needReload = YES;
                    }
                }
            }
            [fm removeItemAtPath:tempDir error:nil]; // 清理临时目录
        } 
        // 字体直装支持
        else if ([ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"] || [ext isEqualToString:@"ttc"]) {
            NSString *destPath = [destDir stringByAppendingPathComponent:[url lastPathComponent]];
            [fm removeItemAtPath:destPath error:nil];
            if ([fm moveItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:nil]) {
                needReload = YES;
            }
        }
    }
    
    if (needReload) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功" message:@"字体已导入并解析，请在列表中选择并注销设备生效。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self reloadSpecifiers]; // 刷新列表，显示新解压出的字体
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)respringAction {
    pid_t pid;
    const char* args[] = {"killall", "-9", "backboardd", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char* const*)args, environ);
}
@end
