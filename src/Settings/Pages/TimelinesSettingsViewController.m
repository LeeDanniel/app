//
//  TimelinesSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/TimelinesSettingsViewController.h"
#import "Headers/TWHeaders.h"
#import "Settings/Pages/ListSortSettingsViewController.h"

extern void applyHideCustomTimelinesSetting(void);

@implementation TimelinesSettingsViewController

- (NSString*)pageKey {
    return @"timelines";
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"hide_custom_timelines"]) {
        applyHideCustomTimelinesSetting();
    }
}

- (void)showListSortSettings:(NSDictionary*)sender {
    ListSortSettingsViewController* vc = [[ListSortSettingsViewController alloc] initWithAccount:self.account];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
