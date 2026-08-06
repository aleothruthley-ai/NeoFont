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

// ================= [修复 1]: 显式声明系统私有 API，解决字典读取越界导致的闪退
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

// ================= [大厂级 UI：原生药丸圆角与背景适配] =================
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

// ================= [动态加载已导入的字体] =================
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
                // 安全调用私有 API 绑定数据源，防止崩溃
                [spec setValues:fontValues titles:fontNames];
            }
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}

// ================= [文件导入核心逻辑 (支持 ZIP/TTF/OTF/TTC)] =================
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
        // [核心修复 2]: 必须开启安全访问权限，否则系统沙盒会拦截读取！
        BOOL isScoped = [url startAccessingSecurityScopedResource];
        NSString *ext = [url.pathExtension lowercaseString];
        
        // 字体直装支持 (必须用 Copy，因原文件可能是只读权限)
        if ([ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"] || [ext isEqualToString:@"ttc"]) {
            NSString *destPath = [destDir stringByAppendingPathComponent:[url lastPathComponent]];
            [fm removeItemAtPath:destPath error:nil];
            if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:nil]) {
                needReload = YES;
            }
        }
        // ZIP 解压支持 (利用 iOS 底层 unzip 命令)
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
                    waitpid(pid, &status, 0); // 等待解压完成
                    
                    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tempDir];
                    for (NSString *subPath in enumerator) {
                        NSString *subExt = [subPath.pathExtension lowercaseString];
                        if ([subExt isEqualToString:@"ttf"] || [subExt isEqualToString:@"otf"] || [subExt isEqualToString:@"ttc"]) {
                            NSString *fullSubPath = [tempDir stringByAppendingPathComponent:subPath];
                            NSString *finalDest = [destDir stringByAppendingPathComponent:[subPath lastPathComponent]];
                            
                            [fm removeItemAtPath:finalDest error:nil]; // 覆盖旧文件
                            if ([fm moveItemAtPath:fullSubPath toPath:finalDest error:nil]) {
                                needReload = YES;
                            }
                        }
                    }
                }
            }
            [fm removeItemAtPath:tempDir error:nil]; // 清理临时目录
        }
        
        if (isScoped) {
            [url stopAccessingSecurityScopedResource];
        }
    }
    
    if (needReload) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功" message:@"字体已导入并解析，请在列表中选择并注销设备生效。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self reloadSpecifiers]; // 刷新列表，显示新字体
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// ================= [兼容有根/无根/RootHide的注销逻辑] =================
- (void)respringAction {
    pid_t pid;
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 1. 无论用哪种方式注销，都先杀掉小组件进程，让小组件立刻刷新
    NSString *killallPath = jbroot(@"/usr/bin/killall");
    if ([fm fileExistsAtPath:killallPath]) {
        const char *args1[] = {"killall", "-9", "widgetkitd", NULL};
        posix_spawn(&pid, [killallPath UTF8String], NULL, NULL, (char *const *)args1, environ);
        waitpid(pid, NULL, 0);
    }
    
    // 2. 优先尝试使用 sbreload (比强杀 backboardd 更干净，大部分越狱环境自带)
    NSString *sbreloadPath = jbroot(@"/usr/bin/sbreload");
    if ([fm fileExistsAtPath:sbreloadPath]) {
        const char *args2[] = {"sbreload", NULL};
        posix_spawn(&pid, [sbreloadPath UTF8String], NULL, NULL, (char *const *)args2, environ);
        return;
    }
    
    // 3. Fallback：如果没有 sbreload，则强杀 backboardd
    if ([fm fileExistsAtPath:killallPath]) {
        const char *args3[] = {"killall", "-9", "backboardd", NULL};
        posix_spawn(&pid, [killallPath UTF8String], NULL, NULL, (char *const *)args3, environ);
    }
}

@end
