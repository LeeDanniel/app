// Tests for src/ListSort/NFBListSortEngine.m: reading X's list timeline JSON, sorting,
// filtering and serving pages. Plain Foundation, so they also run off device.

#import <Foundation/Foundation.h>
#import "ListSort/NFBListSortEngine.h"

static int failures = 0;
static int passes = 0;

static void Check(NSString* name, BOOL ok, NSString* extra) {
    if (ok) {
        passes++;
        printf("  ok   %s\n", name.UTF8String);
        return;
    }
    failures++;
    printf("  FAIL %s %s\n", name.UTF8String, (extra ?: @"").UTF8String);
}

static const NSTimeInterval H = 3600;

static NSString* XDate(NSTimeInterval t) {
    static NSString* const days[] = {@"Sun", @"Mon", @"Tue", @"Wed", @"Thu", @"Fri", @"Sat"};
    static NSString* const mons[] = {@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun", @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"};
    time_t secs = (time_t)t;
    struct tm g;
    gmtime_r(&secs, &g);
    return [NSString stringWithFormat:@"%@ %@ %02d %02d:%02d:%02d +0000 %d", days[g.tm_wday], mons[g.tm_mon], g.tm_mday,
                                      g.tm_hour, g.tm_min, g.tm_sec, g.tm_year + 1900];
}

// A tweet entry shaped like X's GraphQL list timeline.
static NSMutableDictionary* Entry(long long ident, NSDictionary* o) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary* legacy = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id_str": [NSString stringWithFormat:@"%lld", ident],
        @"favorite_count": o[@"likes"] ?: @0,
        @"retweet_count": o[@"reposts"] ?: @0,
        @"reply_count": o[@"replies"] ?: @0,
        @"created_at": XDate(now - [o[@"hoursAgo"] doubleValue] * H),
    }];
    if (o[@"media"]) {
        NSMutableArray* media = [NSMutableArray array];
        for (NSString* t in o[@"media"])
            [media addObject:@{@"type": t}];
        legacy[@"extended_entities"] = @{@"media": media};
    }
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithDictionary:@{
        @"__typename": @"Tweet",
        @"rest_id": legacy[@"id_str"],
        @"core": @{@"user_results": @{@"result": @{@"core": @{@"screen_name": o[@"handle"] ?: @"someone"}}}},
        @"views": @{@"count": [NSString stringWithFormat:@"%@", o[@"views"] ?: @0], @"state": @"EnabledWithCount"},
        @"legacy": legacy,
    }];
    id r = result;
    if ([o[@"visibility"] boolValue]) r = @{@"__typename": @"TweetWithVisibilityResults", @"tweet": result};
    return [NSMutableDictionary dictionaryWithDictionary:@{
        @"entryId": [NSString stringWithFormat:@"tweet-%lld", ident],
        @"sortIndex": [NSString stringWithFormat:@"%lld", 1900000000000000000LL - ident],
        @"content": @{@"entryType": @"TimelineTimelineItem", @"__typename": @"TimelineTimelineItem", @"itemContent": @{@"itemType": @"TimelineTweet", @"__typename": @"TimelineTweet", @"tweet_results": @{@"result": r}}},
    }];
}

static NSDictionary* Result(NSDictionary* entry) {
    id r = entry[@"content"][@"itemContent"][@"tweet_results"][@"result"];
    return r[@"tweet"] ?: r;
}

static NSDictionary* Page(NSArray* entries, NSString* bottom) {
    NSMutableArray* all = [entries mutableCopy];
    [all addObject:@{@"entryId": @"cursor-top-1",
                     @"sortIndex": @"1",
                     @"content": @{@"entryType": @"TimelineTimelineCursor", @"__typename": @"TimelineTimelineCursor", @"value": @"TOPCURSOR", @"cursorType": @"Top"}}];
    if (bottom) {
        [all addObject:@{@"entryId": @"cursor-bottom-1",
                         @"sortIndex": @"0",
                         @"content": @{@"entryType": @"TimelineTimelineCursor", @"__typename": @"TimelineTimelineCursor", @"value": bottom, @"cursorType": @"Bottom", @"stopOnEmptyResponse": @YES}}];
    }
    return @{@"data": @{@"list": @{@"tweets_timeline": @{@"timeline": @{@"instructions": @[
        @{@"type": @"TimelineClearCache"},
        @{@"type": @"TimelinePinEntry",
          @"entry": @{@"entryId": @"pinned"}},
        @{@"type": @"TimelineAddEntries", @"entries": all},
    ]}}}}};
}

static id Roundtrip(id json) {
    return NFBLSParse([NSJSONSerialization dataWithJSONObject:json options:0 error:NULL]);
}

static NSArray* Items(NSArray* entries) {
    NSMutableArray* out = [NSMutableArray array];
    for (NSDictionary* e in entries)
        [out addObject:@{@"entry": e, @"stats": NFBLSStats(e)}];
    return out;
}

static NSString* Ids(NSArray* pool) {
    NSMutableArray* ids = [NSMutableArray array];
    for (NSDictionary* it in pool)
        [ids addObject:it[@"stats"][@"id"]];
    return [ids componentsJoinedByString:@","];
}

static NSString* SortedIds(NSArray* pool) {
    NSMutableArray* ids = [NSMutableArray array];
    for (NSDictionary* it in pool)
        [ids addObject:it[@"stats"][@"id"]];
    [ids sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) { return [@([a longLongValue]) compare:@([b longLongValue])]; }];
    return [ids componentsJoinedByString:@","];
}

int main(void) {
    @autoreleasepool {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        printf("reading X's list timeline\n");
        id page = Roundtrip(Page(@[Entry(1, @{@"likes": @500,
                                              @"reposts": @10,
                                              @"replies": @5,
                                              @"views": @90000,
                                              @"handle": @"Alice",
                                              @"hoursAgo": @2}),
                                   Entry(2, @{@"likes": @"1200",
                                              @"reposts": @"3",
                                              @"replies": @1,
                                              @"views": @"4000",
                                              @"handle": @"bob",
                                              @"visibility": @YES})],
                                 @"BOTTOM1"));
        Check(@"finds the instructions by shape", NFBLSInstructions(page).count == 3, nil);
        Check(@"finds the add-entries instruction", NFBLSAddEntries(page) != nil, nil);
        NSDictionary* split = NFBLSSplit(page);
        Check(@"two posts, cursors not counted", [split[@"items"] count] == 2, nil);
        Check(@"the bottom cursor", [split[@"bottom"] isEqualToString:@"BOTTOM1"], split[@"bottom"]);
        Check(@"keeps the bottom cursor entry as a shape to copy", [split[@"cursorEntry"][@"content"][@"stopOnEmptyResponse"] boolValue], nil);
        NSDictionary* s1 = split[@"items"][0][@"stats"];
        Check(@"likes, reposts, replies, views", [s1[@"likes"] longLongValue] == 500 && [s1[@"reposts"] longLongValue] == 10 && [s1[@"replies"] longLongValue] == 5 && [s1[@"views"] longLongValue] == 90000, s1.description);
        Check(@"handle lowercased", [s1[@"handle"] isEqualToString:@"alice"], s1[@"handle"]);
        Check(@"date read", fabs([s1[@"ts"] doubleValue] - (now - 2 * H)) < 2, [NSString stringWithFormat:@"%f vs %f", [s1[@"ts"] doubleValue], now - 2 * H]);
        NSDictionary* s2 = split[@"items"][1][@"stats"];
        Check(@"counts given as strings", [s2[@"likes"] longLongValue] == 1200 && [s2[@"views"] longLongValue] == 4000, s2.description);
        Check(@"posts from sensitive accounts (wrapped) are read too", [s2[@"id"] isEqualToString:@"2"], nil);
        Check(@"a date in another zone", NFBLSParseDate(@"Wed Oct 10 20:19:24 +0200 2018") == NFBLSParseDate(@"Wed Oct 10 18:19:24 +0000 2018"), nil);
        Check(@"an unreadable date is 0", NFBLSParseDate(@"yesterday") == 0, nil);

        printf("reposts are scored on the original post\n");
        NSMutableDictionary* orig = Entry(555, @{@"likes": @8000,
                                                 @"reposts": @900,
                                                 @"replies": @40,
                                                 @"views": @200000,
                                                 @"hoursAgo": @72,
                                                 @"handle": @"artist"});
        NSMutableDictionary* wrap = Entry(556, @{@"likes": @0,
                                                 @"reposts": @900,
                                                 @"hoursAgo": @2,
                                                 @"handle": @"member"});
        NSMutableDictionary* wr = [Result(wrap) mutableCopy];
        NSMutableDictionary* wl = [wr[@"legacy"] mutableCopy];
        wl[@"retweeted_status_result"] = @{@"result": Result(orig)};
        wr[@"legacy"] = wl;
        [wr removeObjectForKey:@"views"];
        wrap = Roundtrip(@{@"entryId": @"tweet-556",
                           @"sortIndex": @"1",
                           @"content": @{@"entryType": @"TimelineTimelineItem",
                                         @"itemContent": @{@"tweet_results": @{@"result": wr}}}});
        NSDictionary* rs = NFBLSStats(wrap);
        Check(@"likes from the original", [rs[@"likes"] longLongValue] == 8000, nil);
        Check(@"views from the original", [rs[@"views"] longLongValue] == 200000, nil);
        Check(@"flagged as a repost", [rs[@"isRepost"] boolValue], nil);
        Check(@"dated when it was reposted into the list", fabs([rs[@"ts"] doubleValue] - (now - 2 * H)) < 2, nil);
        Check(@"handle is the original author, by is the member", [rs[@"handle"] isEqualToString:@"artist"] && [rs[@"by"] isEqualToString:@"member"], nil);

        printf("sorting\n");
        NSArray* mixed = Items(@[
            Entry(1, @{@"likes": @50,
                       @"reposts": @1,
                       @"replies": @1,
                       @"views": @5000,
                       @"hoursAgo": @2,
                       @"handle": @"a"}),
            Entry(2, @{@"likes": @40,
                       @"reposts": @1,
                       @"replies": @1,
                       @"views": @100,
                       @"hoursAgo": @3,
                       @"handle": @"a"}),
            Entry(3, @{@"likes": @30,
                       @"reposts": @1,
                       @"replies": @1,
                       @"views": @4000,
                       @"hoursAgo": @300,
                       @"handle": @"b"}),
            Entry(4, @{@"likes": @20,
                       @"reposts": @50,
                       @"replies": @1,
                       @"views": @4000,
                       @"hoursAgo": @5,
                       @"handle": @"c"}),
            Entry(5, @{@"likes": @10,
                       @"reposts": @1,
                       @"replies": @90,
                       @"views": @4000,
                       @"hoursAgo": @6,
                       @"handle": @"c"}),
        ]);
        NSDictionary* base = @{@"metric": @0,
                               @"window": @0,
                               @"show": @0,
                               @"reposts": @YES,
                               @"onePerAccount": @NO};
        NSMutableDictionary* st = [base mutableCopy];
        Check(@"likes", [Ids(NFBLSSort(mixed, st, now)[@"pool"]) isEqualToString:@"1,2,3,4,5"], Ids(NFBLSSort(mixed, st, now)[@"pool"]));
        st[@"metric"] = @1;
        Check(@"reposts", [Ids(NFBLSSort(mixed, st, now)[@"pool"]) hasPrefix:@"4,"], nil);
        st[@"metric"] = @2;
        Check(@"replies", [Ids(NFBLSSort(mixed, st, now)[@"pool"]) hasPrefix:@"5,"], nil);
        st[@"metric"] = @4;
        Check(@"likes + 2 x reposts + replies", [Ids(NFBLSSort(mixed, st, now)[@"pool"]) hasPrefix:@"4,5,"], Ids(NFBLSSort(mixed, st, now)[@"pool"]));
        st[@"metric"] = @6;
        Check(@"newest first", [Ids(NFBLSSort(mixed, st, now)[@"pool"]) isEqualToString:@"1,2,4,5,3"], Ids(NFBLSSort(mixed, st, now)[@"pool"]));
        st[@"metric"] = @5;
        NSDictionary* rated = NFBLSSort(mixed, st, now);
        Check(@"engagement rate puts too-few-views last", [Ids(rated[@"pool"]) hasSuffix:@",2"], Ids(rated[@"pool"]));
        Check(@"and counts them", [rated[@"breakdown"][@"lowViews"] intValue] == 1, nil);
        st[@"metric"] = @0;
        st[@"window"] = @168;
        NSDictionary* w = NFBLSSort(mixed, st, now);
        Check(@"window leaves out the old one", [SortedIds(w[@"pool"]) isEqualToString:@"1,2,4,5"] && [w[@"breakdown"][@"window"] intValue] == 1, nil);
        st[@"window"] = @0;
        st[@"onePerAccount"] = @YES;
        NSDictionary* one = NFBLSSort(mixed, st, now);
        Check(@"one per account keeps each account's best", [Ids(one[@"pool"]) isEqualToString:@"1,3,4"] && [one[@"breakdown"][@"dupes"] intValue] == 2, Ids(one[@"pool"]));
        st[@"onePerAccount"] = @NO;
        st[@"reposts"] = @NO;
        NSArray* withRepost = [mixed arrayByAddingObject:@{@"entry": wrap, @"stats": rs}];
        NSDictionary* nr = NFBLSSort(withRepost, st, now);
        Check(@"reposts off leaves reposts out", [nr[@"pool"] count] == 5 && [nr[@"breakdown"][@"reposts"] intValue] == 1, nil);

        printf("Show: videos, pictures, or both\n");
        NSMutableDictionary* quote = Entry(7, @{@"hoursAgo": @1});
        NSMutableDictionary* qr = [Result(quote) mutableCopy];
        qr[@"quoted_status_result"] = @{@"result": Result(Entry(70, @{@"media": @[@"photo"]}))};
        quote = Roundtrip(@{@"entryId": @"tweet-7",
                            @"content": @{@"entryType": @"TimelineTimelineItem", @"itemContent": @{@"tweet_results": @{@"result": qr}}}});
        NSMutableDictionary* rep = Entry(6, @{@"hoursAgo": @1});
        NSMutableDictionary* rr = [Result(rep) mutableCopy];
        NSMutableDictionary* rl = [rr[@"legacy"] mutableCopy];
        rl[@"retweeted_status_result"] = @{@"result": Result(Entry(60, @{@"media": @[@"video"]}))};
        rr[@"legacy"] = rl;
        rep = Roundtrip(@{@"entryId": @"tweet-6",
                          @"content": @{@"entryType": @"TimelineTimelineItem", @"itemContent": @{@"tweet_results": @{@"result": rr}}}});
        NSArray* media = Items(@[
            Entry(1, @{@"media": @[@"video"],
                       @"likes": @99}),
            Entry(2, @{@"media": @[@"animated_gif"],
                       @"likes": @98}),
            Entry(3, @{@"media": @[@"photo", @"photo"],
                       @"likes": @97}),
            Entry(4, @{@"media": @[@"photo", @"video"],
                       @"likes": @96}),
            Entry(5, @{@"likes": @95}),
            rep,
            quote,
            Entry(8, @{@"media": @[@"video"],
                       @"visibility": @YES,
                       @"likes": @1}),
        ]);
        NSMutableDictionary* ms = [base mutableCopy];
        Check(@"All posts keeps everything", [SortedIds(NFBLSSort(media, ms, now)[@"pool"]) isEqualToString:@"1,2,3,4,5,6,7,8"], nil);
        ms[@"show"] = @1;
        Check(@"Videos: video, GIF, mixed, a reposted video, a sensitive one", [SortedIds(NFBLSSort(media, ms, now)[@"pool"]) isEqualToString:@"1,2,4,6,8"], SortedIds(NFBLSSort(media, ms, now)[@"pool"]));
        ms[@"show"] = @2;
        Check(@"Pictures: pictures, mixed, a quoted picture", [SortedIds(NFBLSSort(media, ms, now)[@"pool"]) isEqualToString:@"3,4,7"], SortedIds(NFBLSSort(media, ms, now)[@"pool"]));
        ms[@"show"] = @3;
        Check(@"Videos or pictures", [SortedIds(NFBLSSort(media, ms, now)[@"pool"]) isEqualToString:@"1,2,3,4,6,7,8"], nil);
        ms[@"show"] = @1;
        NSArray* lines = NFBLSDescribe(NFBLSSort(media, ms, now)[@"breakdown"], ms, nil);
        Check(@"the summary says what Show left out", [[lines componentsJoinedByString:@"\n"] rangeOfString:@"3 without a video or GIF (Show is set to Videos)"].location != NSNotFound, [lines componentsJoinedByString:@" | "]);

        printf("the summary\n");
        NSMutableDictionary* ds = [@{@"metric": @5,
                                     @"window": @168,
                                     @"show": @0,
                                     @"reposts": @NO,
                                     @"onePerAccount": @YES} mutableCopy];
        NSArray* withReposts = Items(@[
            Entry(1, @{@"likes": @50,
                       @"views": @5000,
                       @"hoursAgo": @2,
                       @"handle": @"a"}),
            Entry(2, @{@"likes": @40,
                       @"views": @100,
                       @"hoursAgo": @3,
                       @"handle": @"a"}),
            Entry(3, @{@"likes": @30,
                       @"views": @4000,
                       @"hoursAgo": @300,
                       @"handle": @"b"}),
        ]);
        withReposts = [withReposts arrayByAddingObject:@{@"entry": wrap, @"stats": rs}];
        NSArray* sum = NFBLSDescribe(NFBLSSort(withReposts, ds, now)[@"breakdown"], ds, @"Reached the end of the list.");
        Check(@"says how many were scanned and why it stopped", [sum[0] hasPrefix:@"Scanned 4 posts, from "] && [sum[0] hasSuffix:@"Reached the end of the list."], sum[0]);
        Check(@"says how many are shown and the exact sort", [sum[1] isEqualToString:@"Showing 1, sorted by engagement rate, (likes + reposts + replies) ÷ views, highest first."], sum[1]);
        Check(@"names every reason something was left out", [sum[2] rangeOfString:@"1 repost (Reposts is off)"].location != NSNotFound && [sum[2] rangeOfString:@"1 older than the last 7 days"].location != NSNotFound && [sum[2] rangeOfString:@"1 extra from the same account"].location != NSNotFound, sum[2]);

        printf("serving pages\n");
        NSMutableArray* many = [NSMutableArray array];
        for (int i = 1; i <= 45; i++)
            [many addObject:Entry(i, @{@"likes": @(1000 - i),
                                       @"hoursAgo": @1})];
        id tmpl = Roundtrip(Page(@[many[0]], @"REALBOTTOM"));
        NSDictionary* tsplit = NFBLSSplit(tmpl);
        NSArray* pool = NFBLSSort(Items(many), base, now)[@"pool"];
        id p0 = NFBLSParse(NFBLSPage(tmpl, pool, 0, 20, tsplit[@"cursorEntry"], YES));
        NSArray* e0 = NFBLSAddEntries(p0)[@"entries"];
        Check(@"page 0 has 20 posts and our cursor", e0.count == 21, [NSString stringWithFormat:@"%lu", (unsigned long)e0.count]);
        NSDictionary* cur0 = [e0 lastObject];
        Check(@"our cursor continues at 20", NFBLSOffsetOfCursor(cur0[@"content"][@"value"]) == 20, cur0.description);
        Check(@"it keeps the shape of X's own cursor", [cur0[@"content"][@"stopOnEmptyResponse"] boolValue] && [cur0[@"content"][@"cursorType"] isEqualToString:@"Bottom"], nil);
        Check(@"X's own top and bottom cursors are gone", ![[NSJSONSerialization dataWithJSONObject:p0 options:0 error:NULL].description containsString:@"REALBOTTOM"] && [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:p0 options:0 error:NULL] encoding:NSUTF8StringEncoding] rangeOfString:@"TOPCURSOR"].location == NSNotFound, nil);
        BOOL desc = YES;
        for (NSUInteger i = 1; i < e0.count; i++) {
            if ([e0[i][@"sortIndex"] longLongValue] >= [e0[i - 1][@"sortIndex"] longLongValue]) desc = NO;
        }
        Check(@"sort indexes count down, so X keeps our order", desc, nil);
        NSArray* types0 = [NFBLSInstructions(p0) valueForKey:@"type"];
        Check(@"page 0 keeps clear-cache and the pinned post", [types0 containsObject:@"TimelineClearCache"] && [types0 containsObject:@"TimelinePinEntry"], types0.description);
        id p1 = NFBLSParse(NFBLSPage(tmpl, pool, 20, 20, tsplit[@"cursorEntry"], NO));
        NSArray* types1 = [NFBLSInstructions(p1) valueForKey:@"type"];
        Check(@"later pages do not clear or repeat the pin", ![types1 containsObject:@"TimelineClearCache"] && ![types1 containsObject:@"TimelinePinEntry"], types1.description);
        NSArray* e1 = NFBLSAddEntries(p1)[@"entries"];
        Check(@"page 1 continues where page 0 ended", [e1[0][@"sortIndex"] longLongValue] < [e0[19][@"sortIndex"] longLongValue] && [NFBLSStats(e1[0])[@"id"] isEqualToString:@"21"], NFBLSStats(e1[0])[@"id"]);
        id p2 = NFBLSParse(NFBLSPage(tmpl, pool, 40, 20, tsplit[@"cursorEntry"], NO));
        NSArray* e2 = NFBLSAddEntries(p2)[@"entries"];
        Check(@"the last page has the rest and no cursor", e2.count == 5, [NSString stringWithFormat:@"%lu", (unsigned long)e2.count]);
        Check(@"X's cursors are not ours", NFBLSOffsetOfCursor(@"DAABCgABG") == -1 && NFBLSOffsetOfCursor(nil) == -1, nil);

        printf("requests\n");
        Check(@"web's operation is a list timeline", NFBLSIsListTimelineOperation(@"ListLatestTweetsTimeline"), nil);
        Check(@"so is an iOS-style name", NFBLSIsListTimelineOperation(@"ListLatestTweetsTimelineQuery") && NFBLSIsListTimelineOperation(@"ListTimeline"), nil);
        Check(@"members, subscribers and the lists page are not", !NFBLSIsListTimelineOperation(@"ListMembers") && !NFBLSIsListTimelineOperation(@"ListSubscribers") && !NFBLSIsListTimelineOperation(@"ListsManagementPageTimeline") && !NFBLSIsListTimelineOperation(@"CombinedLists") && !NFBLSIsListTimelineOperation(@"HomeTimeline") && !NFBLSIsListTimelineOperation(@"ListAddMember"), nil);
        NSURL* getURL = [NSURL URLWithString:[@"https://api.x.com/graphql/abc123/ListLatestTweetsTimeline?variables="
                                                 stringByAppendingString:@"%7B%22listId%22%3A%22172%22%2C%22count%22%3A20%7D&features=%7B%22a%22%3Atrue%7D"]];
        Check(@"operation name from the path", [NFBLSOperationName(getURL) isEqualToString:@"ListLatestTweetsTimeline"], nil);
        NSDictionary* gv = NFBLSVariables(getURL, nil);
        Check(@"variables from the query", [NFBLSListID(gv) isEqualToString:@"172"], gv.description);
        NSURLRequest* getReq = [NSURLRequest requestWithURL:getURL];
        NSMutableURLRequest* g2 = NFBLSRequestWithVariable(getReq, nil, @"cursor", @"CUR+/=1");
        NSDictionary* gv2 = NFBLSVariables(g2.URL, nil);
        Check(@"cursor set in the query, list kept", [gv2[@"cursor"] isEqualToString:@"CUR+/=1"] && [gv2[@"listId"] isEqualToString:@"172"], gv2.description);
        Check(@"other query items untouched", [g2.URL.absoluteString rangeOfString:@"features=%7B%22a%22%3Atrue%7D"].location != NSNotFound, g2.URL.absoluteString);
        NSDictionary* gv3 = NFBLSVariables(NFBLSRequestWithVariable(g2, nil, @"cursor", nil).URL, nil);
        Check(@"cursor removed", gv3[@"cursor"] == nil && gv3[@"listId"] != nil, nil);
        NSMutableURLRequest* post = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.twitter.com/graphql/xyz/ListTimelineQuery"]];
        post.HTTPMethod = @"POST";
        NSData* body = [NSJSONSerialization dataWithJSONObject:@{@"variables": @{@"list_id": @"99", @"count": @20},
                                                                 @"queryId": @"xyz"}
                                                       options:0
                                                         error:NULL];
        NSDictionary* pv = NFBLSVariables(post.URL, body);
        Check(@"variables from a JSON body", [NFBLSListID(pv) isEqualToString:@"99"], pv.description);
        NSMutableURLRequest* p3 = NFBLSRequestWithVariable(post, body, @"cursor", @"C2");
        NSDictionary* pv2 = NFBLSVariables(p3.URL, p3.HTTPBody);
        Check(@"cursor set in the body", [pv2[@"cursor"] isEqualToString:@"C2"] && [pv2[@"list_id"] isEqualToString:@"99"], pv2.description);
        id bodyRoot = [NSJSONSerialization JSONObjectWithData:p3.HTTPBody options:0 error:NULL];
        Check(@"rest of the body kept", [bodyRoot[@"queryId"] isEqualToString:@"xyz"], nil);
        NSData* strBody = [NSJSONSerialization dataWithJSONObject:@{@"variables": @"{\"listId\":\"5\"}"} options:0 error:NULL];
        NSMutableURLRequest* p4 = NFBLSRequestWithVariable(post, strBody, @"cursor", @"C3");
        Check(@"variables given as a JSON string are handled", [NFBLSVariables(p4.URL, p4.HTTPBody)[@"cursor"] isEqualToString:@"C3"], nil);

        printf("diagnostics\n");
        NSDictionary* shape = NFBLSShape(page);
        Check(@"shape gives the path to the instructions", [shape[@"path"] isEqualToString:@"data.list.tweets_timeline.timeline.instructions"], shape[@"path"]);
        Check(@"and the entry kinds", shape[@"entryKinds"][@"TimelineTimelineItem"] != nil && shape[@"entryKinds"][@"TimelineTimelineCursor"] != nil, nil);
        NSString* shapeText = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:shape options:0 error:NULL] encoding:NSUTF8StringEncoding];
        Check(@"no post content in it (names only)", [shapeText rangeOfString:@"alice"].location == NSNotFound && [shapeText rangeOfString:@"BOTTOM1"].location == NSNotFound, shapeText);
        Check(@"unknown JSON does not crash", NFBLSSplit(@{@"x": @[@1, @{@"instructions": @"nope"}]}) != nil && NFBLSPage(@{}, @[], 0, 20, nil, YES) == nil, nil);
    }
    printf(failures ? "\n%d FAILED\n" : "\nall %d passed\n", failures ? failures : passes);
    return failures ? 1 : 0;
}
