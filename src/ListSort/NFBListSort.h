//
//  NFBListSort.h
//  NeoFreeBird
//
//  List sorting, shared between the hook (Hooks/ListSort.x) and the settings page.
//

#import <Foundation/Foundation.h>

// Setting keys (NSUserDefaults, registered in BHTSettings under the "list_sorting" page)
#define NFBLSKeyPopular       @"list_sort_popular"
#define NFBLSKeyMetric        @"list_sort_metric"
#define NFBLSKeyTimeWindow    @"list_sort_window"
#define NFBLSKeyShow          @"list_sort_show"
#define NFBLSKeyReposts       @"list_sort_reposts"
#define NFBLSKeyOnePerAccount @"list_sort_one_per_account"
#define NFBLSKeyButton        @"list_sort_button"

// Choices, as @[ @[value, label], ... ] in menu order.
NSArray<NSArray*>* NFBListSortMetricChoices(void);
NSArray<NSArray*>* NFBListSortWindowChoices(void);
NSArray<NSArray*>* NFBListSortShowChoices(void);
NSString* NFBListSortLabelFor(NSArray<NSArray*>* choices, NSInteger value);

// The current settings in the shape NFBLSSort takes.
NSDictionary* NFBListSortCurrentSettings(void);

// Forget every saved scan, so each list is scanned again the next time it opens.
void NFBListSortForgetScans(void);

// What the script has seen, for pasting into a bug report. Names and counts only, never post text.
NSString* NFBListSortDiagnostics(void);

// The settings changed (from the settings page or the list button): menus and buttons refresh.
void NFBListSortSettingsChanged(void);
