//
//  ListSortSettingsViewController.m
//  NeoFreeBird
//
//  Settings for list sorting (Hooks/ListSort.x). The same choices are on the button shown on lists.
//

#import "Settings/Pages/ListSortSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Headers/TWHeaders.h"
#import "ListSort/NFBListSort.h"
#import "Settings/ModernSettingsCells.h"

@implementation ListSortSettingsViewController

- (NSString*)pageKey {
    return @"list_sorting";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // The list button changes the same settings: keep this page in step with it.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsChangedElsewhere:)
                                                 name:@"NFBListSortSettingsChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)settingsChangedElsewhere:(NSNotification*)note {
    [self.tableView reloadData];
}

- (NSArray<NSArray*>*)choicesForKey:(NSString*)key {
    if ([key isEqualToString:NFBLSKeyMetric]) return NFBListSortMetricChoices();
    if ([key isEqualToString:NFBLSKeyTimeWindow]) return NFBListSortWindowChoices();
    if ([key isEqualToString:NFBLSKeyShow]) return NFBListSortShowChoices();
    return nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* settingData = self.visibleToggles[indexPath.row];
    NSArray* choices = [self choicesForKey:settingData[@"key"]];
    if (choices) {
        ModernSettingsCompactButtonCell* cell = [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                                                                forIndexPath:indexPath];
        NSString* title = [[BHTBundle sharedBundle] localizedStringForKey:settingData[@"titleKey"]];
        [cell configureWithTitle:title
                        subtitle:NFBListSortLabelFor(choices, [BHTSettings integerForKey:settingData[@"key"]])];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NFBListSortSettingsChanged();
}

- (void)showPickerForKey:(NSString*)key titleKey:(NSString*)titleKey {
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:titleKey]
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    NSInteger current = [BHTSettings integerForKey:key];
    for (NSArray* choice in [self choicesForKey:key]) {
        NSInteger value = [choice[0] integerValue];
        NSString* label = value == current ? [choice[1] stringByAppendingString:@" ✓"] : choice[1];
        [alert addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [[NSUserDefaults standardUserDefaults] setInteger:value forKey:key];
                                                    [self.tableView reloadData];
                                                    NFBListSortSettingsChanged();
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showListSortMetricPicker:(NSDictionary*)sender {
    [self showPickerForKey:NFBLSKeyMetric titleKey:@"LIST_SORT_METRIC_TITLE"];
}

- (void)showListSortWindowPicker:(NSDictionary*)sender {
    [self showPickerForKey:NFBLSKeyTimeWindow titleKey:@"LIST_SORT_WINDOW_TITLE"];
}

- (void)showListSortShowPicker:(NSDictionary*)sender {
    [self showPickerForKey:NFBLSKeyShow titleKey:@"LIST_SORT_SHOW_TITLE"];
}

- (void)showMessageWithTitleKey:(NSString*)titleKey messageKey:(NSString*)messageKey {
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:titleKey]
                         message:[[BHTBundle sharedBundle] localizedStringForKey:messageKey]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"OK_ACTION_LABEL"]
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)forgetListSortScans:(NSDictionary*)sender {
    NFBListSortForgetScans();
    [self showMessageWithTitleKey:@"LIST_SORT_FORGET_TITLE" messageKey:@"LIST_SORT_FORGET_DONE"];
}

- (void)copyListSortDiagnostics:(NSDictionary*)sender {
    [UIPasteboard generalPasteboard].string = NFBListSortDiagnostics();
    [self showMessageWithTitleKey:@"LIST_SORT_DIAGNOSTICS_TITLE" messageKey:@"LIST_SORT_DIAGNOSTICS_DONE"];
}

@end
