//
//  NFBListSortEngine.h
//  NeoFreeBird
//
//  List sorting: the part that only deals with X's timeline JSON. No UIKit and no
//  networking here, so it can be unit tested off device. Ported from the x-list-sort
//  userscript (3.6.0), which does the same thing on x.com.
//
//  A list timeline response looks like (field names are X's GraphQL schema, shared by
//  web and iOS):
//    { data: { list: { tweets_timeline: { timeline: { instructions: [
//        { type: "TimelineAddEntries", entries: [ <tweet entries>, <cursor entries> ] }, ... ] } } } } }
//  The wrapper path is not relied on: the instruction list is found by its shape.
//

#import <Foundation/Foundation.h>

// Metrics (values of the list_sort_metric setting)
typedef NS_ENUM(NSInteger, NFBListSortMetric) {
    NFBListSortMetricLikes = 0,
    NFBListSortMetricReposts = 1,
    NFBListSortMetricReplies = 2,
    NFBListSortMetricViews = 3,
    NFBListSortMetricCombined = 4, // likes + 2 x reposts + replies
    NFBListSortMetricRate = 5,     // (likes + reposts + replies) / views
    NFBListSortMetricNewest = 6,
};

// What to keep (values of the list_sort_show setting). GIFs count as video.
typedef NS_ENUM(NSInteger, NFBListSortShow) {
    NFBListSortShowAll = 0,
    NFBListSortShowVideos = 1,
    NFBListSortShowPictures = 2,
    NFBListSortShowMedia = 3, // videos or pictures
};

// Our own cursor values start with this, so a request for the next page of a sorted list
// can be told apart from X's.
extern NSString* const NFBListSortCursorPrefix;

// Posts with fewer views than this have no engagement rate (it would be noise).
extern const long long NFBListSortMinViewsForRate;

#pragma mark - Reading responses

// Parses response data into mutable containers, or nil.
id NFBLSParse(NSData* data);

// The instruction array, found by shape anywhere in the response.
NSMutableArray* NFBLSInstructions(id json);

// The instruction that adds entries (type or __typename "TimelineAddEntries").
NSMutableDictionary* NFBLSAddEntries(id json);

// Splits a response into posts and the bottom cursor:
//   @{ @"items": @[ @{ @"entry": entry, @"stats": stats }, ... ],
//      @"bottom": cursor value or missing,
//      @"cursorEntry": the bottom cursor entry itself (a shape to copy) or missing }
NSDictionary* NFBLSSplit(id json);

// Numbers for one entry, or nil if it is not a post:
//   id, handle (author of the original), by (who posted it into the list), ts (seconds),
//   isRepost, likes, reposts, replies, views
NSDictionary* NFBLSStats(NSDictionary* entry);

// What is attached: @{ @"video": @(BOOL), @"photo": @(BOOL) }. Its own media, the original's
// for a repost, and a quoted post's.
NSDictionary* NFBLSMedia(NSDictionary* entry);

// X's created_at, "Wed Oct 10 20:19:24 +0000 2018", in seconds since 1970. 0 if unreadable.
NSTimeInterval NFBLSParseDate(NSString* s);

#pragma mark - Sorting

// settings: @{ @"metric": @(NFBListSortMetric), @"window": @(hours, 0 = no limit),
//              @"show": @(NFBListSortShow), @"reposts": @(BOOL), @"onePerAccount": @(BOOL) }
// now: the time to measure the window from.
// Returns @{ @"pool": sorted items, @"breakdown": @{ loaded, shown, window, reposts, media, dupes,
//            lowViews, oldest, newest } }
NSDictionary* NFBLSSort(NSArray* items, NSDictionary* settings, NSTimeInterval now);

double NFBLSScore(NSDictionary* stats, NSInteger metric);

// One plain sentence per line describing what was scanned, shown and left out.
NSArray<NSString*>* NFBLSDescribe(NSDictionary* breakdown, NSDictionary* settings, NSString* stopped);

#pragma mark - Serving pages

// A page of the sorted pool, in the shape of `template` (a real response for this list).
// Entries get descending sort indexes so X keeps our order. If more remain, a bottom cursor
// "NFB|<next offset>" is added, copied from `cursorEntry` when there is one.
// firstPage: keep instructions like TimelineClearCache from the template (only on page 0).
NSData* NFBLSPage(id template_, NSArray* pool, NSUInteger offset, NSUInteger pageSize,
                  NSDictionary* cursorEntry, BOOL firstPage);

// The offset in one of our cursors, or -1 if it is not ours.
NSInteger NFBLSOffsetOfCursor(id cursor);

#pragma mark - Requests

// The GraphQL operation name: the last path component of .../graphql/<queryId>/<Operation>.
NSString* NFBLSOperationName(NSURL* url);

// Whether an operation is a list's post timeline (not members, subscribers, management...).
BOOL NFBLSIsListTimelineOperation(NSString* operation);

// The request's GraphQL variables, from the "variables" query item or the JSON body.
NSDictionary* NFBLSVariables(NSURL* url, NSData* body);

// The list id in a list timeline's variables, or nil.
NSString* NFBLSListID(NSDictionary* variables);

// A copy of the request with one variable changed (nil value removes it), wherever the
// variables live (query or JSON body). The body is passed separately because inside a URL
// protocol it usually arrives as a stream.
NSMutableURLRequest* NFBLSRequestWithVariable(NSURLRequest* request, NSData* body,
                                              NSString* key, id value);

#pragma mark - Diagnostics

// The names (never the contents) of the fields in a response, to see how X shapes it.
NSDictionary* NFBLSShape(id json);
