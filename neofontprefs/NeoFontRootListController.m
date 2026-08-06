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

// [修复 1]: 显式声明系统私有 API，既能通过严苛的编译，又能完美配置数组，彻底解决点击闪退！
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
                // 安全调用私有 API 绑定数据源
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
        // [修复 2]: 必须开启安全访问权限，否则系统直接拦截读取请求！
        BOOL isScoped = [url startAccessingSecurityScopedResource];
        NSString *ext = [url.pathExtension lowercaseString];
        
        // 字体直装支持 (必须用 Copy 而不能用 Move，因为原文件可能是只读沙盒权限)
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
            
            // 核心修复：必须把安全沙盒内的 ZIP 复制到我们自己App的临时目录下，外部的 unzip 子进程才有权限读取！
            NSString *tempZipPath = [tempDir stringByAppendingPathComponent:@"temp.zip"];
            if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tempZipPath] error:nil]) {
                
                pid_t pid;
                NSString *unzipPath = jbroot(@"/usr/bin/unzip");
                const char *argv[] = {"unzip", "-o", [tempZipPath UTF8String], "-d", [tempDir UTF8String], NULL};
                int status = posix_spawn(&pid, [unzipPath UTF8String], NULL, NULL, (char* const*)argv, environ);
                
                if (status == 0) {
                    waitpid(pid, &status, 0); // 等待解压完成
                    
                    // 遍历解压出的目录寻找字体文件
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
        
        // 务必关闭安全权限
        if (isScoped) {
            [url stopAccessingSecurityScopedResource];
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
