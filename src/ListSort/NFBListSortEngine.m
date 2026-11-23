//
//  NFBListSortEngine.m
//  NeoFreeBird
//

#import "NFBListSortEngine.h"
#include <time.h>

NSString* const NFBListSortCursorPrefix = @"NFB|";
const long long NFBListSortMinViewsForRate = 300;

// X's sort indexes are 19-digit numbers. Ours count down from here, well below real ones.
static const long long NFBLSSortBase = 1800000000000000000LL;

#pragma mark - Small helpers

static NSDictionary* D(id container, NSString* key) {
    if (![container isKindOfClass:[NSDictionary class]]) return nil;
    id v = [(NSDictionary*)container objectForKey:key];
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

static NSString* S(id container, NSString* key) {
    if (![container isKindOfClass:[NSDictionary class]]) return nil;
    id v = [(NSDictionary*)container objectForKey:key];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v stringValue];
    return nil;
}

// Counts arrive as numbers, or as strings ("12345", and on some fields "1.2K" is never used,
// but strip anything that is not a digit to be safe).
static long long N(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v longLongValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString* s = v;
        NSMutableString* digits = [NSMutableString string];
        for (NSUInteger i = 0; i < s.length; i++) {
            unichar c = [s characterAtIndex:i];
            if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
        }
        return digits.length ? [digits longLongValue] : 0;
    }
    return 0;
}

static NSString* TypeOf(NSDictionary* node) {
    return S(node, @"entryType") ?: S(node, @"__typename") ?
                                                           : S(node, @"type");
}

id NFBLSParse(NSData* data) {
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
}

static id DeepMutableCopy(id json) {
    if (!json) return nil;
    NSData* d = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    return d ? NFBLSParse(d) : nil;
}

#pragma mark - Reading responses

NSMutableArray* NFBLSInstructions(id json) {
    NSMutableArray* stack = [NSMutableArray arrayWithObject:json ?: [NSNull null]];
    NSUInteger guard = 0;
    while (stack.count && guard++ < 100000) {
        id node = [stack lastObject];
        [stack removeLastObject];
        if ([node isKindOfClass:[NSDictionary class]]) {
            id ins = [(NSDictionary*)node objectForKey:@"instructions"];
            if ([ins isKindOfClass:[NSArray class]]) {
                for (id i in (NSArray*)ins) {
                    if ([i isKindOfClass:[NSDictionary class]] && TypeOf(i)) return ins;
                }
            }
            for (id v in [(NSDictionary*)node allValues]) {
                if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) [stack addObject:v];
            }
        } else if ([node isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray*)node) {
                if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) [stack addObject:v];
            }
        }
    }
    return nil;
}

NSMutableDictionary* NFBLSAddEntries(id json) {
    for (id i in NFBLSInstructions(json)) {
        if (![i isKindOfClass:[NSDictionary class]]) continue;
        NSString* t = S(i, @"type") ?: S(i, @"__typename");
        if ([t isEqualToString:@"TimelineAddEntries"] && [[i objectForKey:@"entries"] isKindOfClass:[NSArray class]]) return i;
    }
    return nil;
}

static NSDictionary* Unwrap(NSDictionary* r) {
    if ([S(r, @"__typename") isEqualToString:@"TweetWithVisibilityResults"] && D(r, @"tweet")) return D(r, @"tweet");
    return r;
}

static NSDictionary* TweetResult(NSDictionary* entry) {
    NSDictionary* c = D(entry, @"content");
    if (!c || ![TypeOf(c) isEqualToString:@"TimelineTimelineItem"]) return nil;
    NSDictionary* ic = D(c, @"itemContent") ?: D(c, @"content");
    NSDictionary* tr = D(ic, @"tweet_results") ?: D(ic, @"tweetResult");
    NSDictionary* r = Unwrap(D(tr, @"result"));
    return D(r, @"legacy") ? r : nil;
}

static NSString* HandleOf(NSDictionary* r) {
    NSDictionary* user = D(D(D(r, @"core"), @"user_results"), @"result");
    NSString* h = S(D(user, @"core"), @"screen_name") ?: S(D(user, @"legacy"), @"screen_name") ?
                                                                                               : @"";
    return [h lowercaseString];
}

NSTimeInterval NFBLSParseDate(NSString* s) {
    if (![s isKindOfClass:[NSString class]]) return 0;
    // Wed Oct 10 20:19:24 +0000 2018
    NSArray* parts = [s componentsSeparatedByString:@" "];
    if (parts.count != 6) return 0;
    NSArray* months = @[@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun", @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"];
    NSUInteger mon = [months indexOfObject:parts[1]];
    NSArray* hms = [parts[3] componentsSeparatedByString:@":"];
    if (mon == NSNotFound || hms.count != 3) return 0;
    struct tm t;
    memset(&t, 0, sizeof t);
    t.tm_year = [parts[5] intValue] - 1900;
    t.tm_mon = (int)mon;
    t.tm_mday = [parts[2] intValue];
    t.tm_hour = [hms[0] intValue];
    t.tm_min = [hms[1] intValue];
    t.tm_sec = [hms[2] intValue];
    time_t secs = timegm(&t);
    NSString* z = parts[4]; // +hhmm
    if (z.length == 5) {
        int sign = [z hasPrefix:@"-"] ? -1 : 1;
        int hh = [[z substringWithRange:NSMakeRange(1, 2)] intValue];
        int mm = [[z substringWithRange:NSMakeRange(3, 2)] intValue];
        secs -= sign * (hh * 3600 + mm * 60);
    }
    return (NSTimeInterval)secs;
}

NSDictionary* NFBLSStats(NSDictionary* entry) {
    NSDictionary* r = TweetResult(entry);
    if (!r) return nil;
    NSDictionary* lg = D(r, @"legacy");
    // A repost is a wrapper with its own near-zero counts; the real numbers are on the original.
    NSDictionary* orig = Unwrap(D(D(lg, @"retweeted_status_result"), @"result"));
    NSDictionary* src = D(orig, @"legacy") ? orig : r;
    NSDictionary* sl = D(src, @"legacy");
    BOOL isRepost = (src != r) || D(lg, @"retweeted_status_result") != nil;
    NSString* ident = S(lg, @"id_str") ?: S(r, @"rest_id") ?
                                                           : @"";
    return @{
        @"id": ident,
        @"handle": HandleOf(src),
        @"by": HandleOf(r),
        @"ts": @(NFBLSParseDate(S(lg, @"created_at"))),
        @"isRepost": @(isRepost),
        @"likes": @(N([sl objectForKey:@"favorite_count"])),
        @"reposts": @(N([sl objectForKey:@"retweet_count"])),
        @"replies": @(N([sl objectForKey:@"reply_count"])),
        @"views": @(N([D(src, @"views") objectForKey:@"count"])),
    };
}

static void LookForMedia(NSDictionary* r, int depth, BOOL* video, BOOL* photo) {
    r = Unwrap(r);
    NSDictionary* lg = D(r, @"legacy");
    if (!lg || depth > 2) return;
    id list = [D(lg, @"extended_entities") objectForKey:@"media"];
    if (![list isKindOfClass:[NSArray class]]) list = [D(lg, @"entities") objectForKey:@"media"];
    if ([list isKindOfClass:[NSArray class]]) {
        for (id m in (NSArray*)list) {
            NSString* t = S(m, @"type");
            if ([t isEqualToString:@"video"] || [t isEqualToString:@"animated_gif"]) *video = YES;
            else if ([t isEqualToString:@"photo"]) *photo = YES;
        }
    }
    LookForMedia(D(D(lg, @"retweeted_status_result"), @"result"), depth + 1, video, photo);
    LookForMedia(D(D(r, @"quoted_status_result"), @"result"), depth + 1, video, photo);
}

NSDictionary* NFBLSMedia(NSDictionary* entry) {
    BOOL video = NO, photo = NO;
    LookForMedia(TweetResult(entry), 0, &video, &photo);
    return @{@"video": @(video),
             @"photo": @(photo)};
}

static NSString* CursorType(NSDictionary* c) {
    return S(c, @"cursorType") ?: S(c, @"cursor_type") ?
                                                       : S(D(c, @"itemContent"), @"cursorType");
}

static NSString* CursorValue(NSDictionary* c) {
    return S(c, @"value") ?: S(D(c, @"itemContent"), @"value");
}

NSDictionary* NFBLSSplit(id json) {
    NSMutableArray* items = [NSMutableArray array];
    NSString* bottom = nil;
    NSDictionary* cursorEntry = nil;
    NSDictionary* add = NFBLSAddEntries(json);
    for (id e in (NSArray*)[add objectForKey:@"entries"]) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary* c = D(e, @"content");
        NSString* t = TypeOf(c);
        if ([t isEqualToString:@"TimelineTimelineCursor"] || [t isEqualToString:@"TimelineCursor"]) {
            if ([CursorType(c) isEqualToString:@"Bottom"]) {
                bottom = CursorValue(c);
                cursorEntry = e;
            }
            continue;
        }
        NSDictionary* s = NFBLSStats(e);
        if (s) [items addObject:@{@"entry": e, @"stats": s}];
    }
    NSMutableDictionary* out = [NSMutableDictionary dictionaryWithObject:items forKey:@"items"];
    if (bottom) [out setObject:bottom forKey:@"bottom"];
    if (cursorEntry) [out setObject:cursorEntry forKey:@"cursorEntry"];
    return out;
}

#pragma mark - Sorting

double NFBLSScore(NSDictionary* s, NSInteger metric) {
    double likes = [[s objectForKey:@"likes"] doubleValue], reposts = [[s objectForKey:@"reposts"] doubleValue];
    double replies = [[s objectForKey:@"replies"] doubleValue], views = [[s objectForKey:@"views"] doubleValue];
    switch (metric) {
        case NFBListSortMetricReposts:
            return reposts;
        case NFBListSortMetricReplies:
            return replies;
        case NFBListSortMetricViews:
            return views;
        case NFBListSortMetricCombined:
            return likes + 2 * reposts + replies;
        case NFBListSortMetricRate:
            if (views < NFBListSortMinViewsForRate) return -1;
            return (likes + reposts + replies) / views;
        case NFBListSortMetricNewest:
            return [[s objectForKey:@"ts"] doubleValue];
        default:
            return likes;
    }
}

static BOOL PassesShow(NSDictionary* entry, NSInteger show) {
    if (show == NFBListSortShowAll) return YES;
    NSDictionary* m = NFBLSMedia(entry);
    BOOL v = [[m objectForKey:@"video"] boolValue], p = [[m objectForKey:@"photo"] boolValue];
    if (show == NFBListSortShowVideos) return v;
    if (show == NFBListSortShowPictures) return p;
    return v || p;
}

NSDictionary* NFBLSSort(NSArray* items, NSDictionary* settings, NSTimeInterval now) {
    NSInteger metric = [[settings objectForKey:@"metric"] integerValue];
    NSInteger window = [[settings objectForKey:@"window"] integerValue];
    NSInteger show = [[settings objectForKey:@"show"] integerValue];
    id repostsSetting = [settings objectForKey:@"reposts"];
    BOOL reposts = repostsSetting ? [repostsSetting boolValue] : YES;
    BOOL onePer = [[settings objectForKey:@"onePerAccount"] boolValue];
    NSTimeInterval cutoff = window > 0 ? now - window * 3600.0 : 0;

    long removedWindow = 0, removedReposts = 0, removedMedia = 0, removedDupes = 0;
    NSTimeInterval oldest = 0, newest = 0;
    NSMutableArray* out = [NSMutableArray array];
    for (NSDictionary* it in items) {
        NSDictionary* s = [it objectForKey:@"stats"];
        NSTimeInterval t = [[s objectForKey:@"ts"] doubleValue];
        if (t) {
            oldest = oldest ? MIN(oldest, t) : t;
            newest = MAX(newest, t);
        }
        if (cutoff && t && t < cutoff) {
            removedWindow++;
            continue;
        }
        if (!reposts && [[s objectForKey:@"isRepost"] boolValue]) {
            removedReposts++;
            continue;
        }
        if (!PassesShow([it objectForKey:@"entry"], show)) {
            removedMedia++;
            continue;
        }
        [out addObject:it];
    }
    [out sortWithOptions:NSSortStable
         usingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
             NSDictionary* sa = [a objectForKey:@"stats"];
             NSDictionary* sb = [b objectForKey:@"stats"];
             double x = NFBLSScore(sa, metric), y = NFBLSScore(sb, metric);
             if (x != y) return x > y ? NSOrderedAscending : NSOrderedDescending;
             double ta = [[sa objectForKey:@"ts"] doubleValue], tb = [[sb objectForKey:@"ts"] doubleValue];
             if (ta != tb) return ta > tb ? NSOrderedAscending : NSOrderedDescending;
             return NSOrderedSame;
         }];
    if (onePer) {
        NSMutableSet* seen = [NSMutableSet set];
        NSMutableArray* kept = [NSMutableArray array];
        for (NSDictionary* it in out) {
            NSString* h = [[it objectForKey:@"stats"] objectForKey:@"handle"] ?: @"";
            if ([seen containsObject:h]) {
                removedDupes++;
                continue;
            }
            [seen addObject:h];
            [kept addObject:it];
        }
        out = kept;
    }
    long lowViews = 0;
    if (metric == NFBListSortMetricRate) {
        for (NSDictionary* it in out)
            if (NFBLSScore([it objectForKey:@"stats"], metric) < 0) lowViews++;
    }
    NSDictionary* breakdown = @{
        @"loaded": @(items.count),
        @"shown": @(out.count),
        @"window": @(removedWindow),
        @"reposts": @(removedReposts),
        @"media": @(removedMedia),
        @"dupes": @(removedDupes),
        @"lowViews": @(lowViews),
        @"oldest": @(oldest),
        @"newest": @(newest),
    };
    return @{@"pool": out, @"breakdown": breakdown};
}

static NSString* ShortDate(NSTimeInterval ts) {
    NSDateFormatter* f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MMM d";
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

NSArray<NSString*>* NFBLSDescribe(NSDictionary* b, NSDictionary* settings, NSString* stopped) {
    if (!b) return @[];
    static NSString* const sortText[] = {
        @"most likes first",
        @"most reposts first",
        @"most replies first",
        @"most views first",
        @"likes + 2 × reposts + replies, highest first",
        @"engagement rate, (likes + reposts + replies) ÷ views, highest first",
        @"newest first",
    };
    static NSString* const showText[] = {@"", @"a video or GIF", @"a picture", @"a video, GIF or picture"};
    static NSString* const showLabel[] = {@"", @"Videos", @"Pictures", @"Videos or pictures"};
    NSInteger metric = MAX(0, MIN(6, [[settings objectForKey:@"metric"] integerValue]));
    NSInteger show = MAX(0, MIN(3, [[settings objectForKey:@"show"] integerValue]));
    NSInteger window = [[settings objectForKey:@"window"] integerValue];
    NSMutableArray* lines = [NSMutableArray array];
    NSTimeInterval oldest = [[b objectForKey:@"oldest"] doubleValue];
    NSString* first = [NSString stringWithFormat:@"Scanned %@ posts%@.", [b objectForKey:@"loaded"],
                                                 oldest ? [NSString stringWithFormat:@", from %@ to now", ShortDate(oldest)] : @""];
    if (stopped.length) first = [first stringByAppendingFormat:@" %@", stopped];
    [lines addObject:first];
    [lines addObject:[NSString stringWithFormat:@"Showing %@, sorted by %@.", [b objectForKey:@"shown"], sortText[metric]]];
    NSMutableArray* out = [NSMutableArray array];
    long r = [[b objectForKey:@"reposts"] longValue];
    if (r) [out addObject:[NSString stringWithFormat:@"%ld repost%@ (Reposts is off)", r, r == 1 ? @"" : @"s"]];
    long w = [[b objectForKey:@"window"] longValue];
    if (w) {
        NSString* span = window == 6 ? @"last 6 hours" : window == 24 ? @"last 24 hours"
                                                     : window == 72   ? @"last 3 days"
                                                     : window == 168  ? @"last 7 days"
                                                     : window == 720  ? @"last 30 days"
                                                                      : [NSString stringWithFormat:@"last %ld hours", (long)window];
        [out addObject:[NSString stringWithFormat:@"%ld older than the %@", w, span]];
    }
    long m = [[b objectForKey:@"media"] longValue];
    if (m) [out addObject:[NSString stringWithFormat:@"%ld without %@ (Show is set to %@)", m, showText[show], showLabel[show]]];
    long d = [[b objectForKey:@"dupes"] longValue];
    if (d) [out addObject:[NSString stringWithFormat:@"%ld extra from the same account (One per account is on)", d]];
    if (out.count) [lines addObject:[NSString stringWithFormat:@"Left out: %@.", [out componentsJoinedByString:@", "]]];
    long low = [[b objectForKey:@"lowViews"] longValue];
    if (low) [lines addObject:[NSString stringWithFormat:@"%ld with under %lld views are at the bottom, too few views to rate fairly.", low, NFBListSortMinViewsForRate]];
    return lines;
}

#pragma mark - Serving pages

static NSString* SortIndex(NSUInteger n) {
    return [NSString stringWithFormat:@"%lld", NFBLSSortBase - (long long)n * 10];
}

NSInteger NFBLSOffsetOfCursor(id cursor) {
    if (![cursor isKindOfClass:[NSString class]] || ![(NSString*)cursor hasPrefix:NFBListSortCursorPrefix]) return -1;
    NSString* rest = [(NSString*)cursor substringFromIndex:NFBListSortCursorPrefix.length];
    NSInteger n = [rest integerValue];
    return n >= 0 ? n : -1;
}

static NSMutableDictionary* CursorEntry(NSDictionary* shape, NSString* value, NSString* sortIndex) {
    NSMutableDictionary* e = shape ? DeepMutableCopy(shape) : nil;
    if (![e isKindOfClass:[NSMutableDictionary class]]) {
        e = [NSMutableDictionary dictionary];
        [e setObject:[NSMutableDictionary dictionaryWithDictionary:@{
               @"entryType": @"TimelineTimelineCursor",
               @"__typename": @"TimelineTimelineCursor",
               @"cursorType": @"Bottom"
           }]
              forKey:@"content"];
    }
    [e setObject:[@"cursor-bottom-" stringByAppendingString:sortIndex] forKey:@"entryId"];
    [e setObject:sortIndex forKey:@"sortIndex"];
    NSMutableDictionary* c = [e objectForKey:@"content"];
    if ([[c objectForKey:@"itemContent"] isKindOfClass:[NSMutableDictionary class]] && ![c objectForKey:@"value"]) {
        [[c objectForKey:@"itemContent"] setObject:value forKey:@"value"];
    } else {
        [c setObject:value forKey:@"value"];
    }
    return e;
}

NSData* NFBLSPage(id template_, NSArray* pool, NSUInteger offset, NSUInteger pageSize,
                  NSDictionary* cursorEntry, BOOL firstPage) {
    id json = DeepMutableCopy(template_);
    NSMutableDictionary* add = NFBLSAddEntries(json);
    if (!add) return nil;
    NSMutableArray* instructions = NFBLSInstructions(json);
    NSMutableIndexSet* drop = [NSMutableIndexSet indexSet];
    [instructions enumerateObjectsUsingBlock:^(id ins, NSUInteger idx, BOOL* stop) {
        if (ins == add || ![ins isKindOfClass:[NSMutableDictionary class]]) return;
        NSString* t = S(ins, @"type") ?: S(ins, @"__typename");
        // Clearing the timeline only makes sense with the first page; later pages add to it.
        if (!firstPage && [t isEqualToString:@"TimelineClearCache"]) {
            [drop addIndex:idx];
            return;
        }
        // Other entry lists belong to X's order, not ours. A pinned post stays at the top of the
        // first page, as it does on x.com, and is not repeated on later pages.
        if ([[ins objectForKey:@"entries"] isKindOfClass:[NSArray class]]) [ins setObject:[NSMutableArray array] forKey:@"entries"];
        if (!firstPage && [t isEqualToString:@"TimelinePinEntry"]) [drop addIndex:idx];
    }];
    [instructions removeObjectsAtIndexes:drop];

    NSMutableArray* entries = [NSMutableArray array];
    NSUInteger end = MIN(pool.count, offset + pageSize);
    for (NSUInteger i = offset; i < end; i++) {
        NSMutableDictionary* e = DeepMutableCopy([[pool objectAtIndex:i] objectForKey:@"entry"]);
        if (!e) continue;
        [e setObject:SortIndex(i) forKey:@"sortIndex"];
        [entries addObject:e];
    }
    if (end < pool.count) {
        NSString* value = [NFBListSortCursorPrefix stringByAppendingFormat:@"%lu", (unsigned long)end];
        [entries addObject:CursorEntry(cursorEntry, value, SortIndex(end))];
    }
    [add setObject:entries forKey:@"entries"];
    return [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
}

#pragma mark - Requests

NSString* NFBLSOperationName(NSURL* url) {
    NSString* path = url.path ?: @"";
    if ([path rangeOfString:@"/graphql/"].location == NSNotFound) return nil;
    NSString* last = [path lastPathComponent];
    return last.length ? last : nil;
}

BOOL NFBLSIsListTimelineOperation(NSString* op) {
    if (op.length == 0) return NO;
    NSString* lower = [op lowercaseString];
    if ([lower rangeOfString:@"list"].location == NSNotFound) return NO;
    if ([lower rangeOfString:@"timeline"].location == NSNotFound && [lower rangeOfString:@"tweets"].location == NSNotFound) return NO;
    // Not the list's members, followers, settings or the lists overview.
    for (NSString* no in @[@"member", @"subscriber", @"ownership", @"management", @"create", @"delete", @"update",
                           @"add", @"remove", @"pin", @"suggest", @"discover", @"search", @"listslist", @"combined",
                           @"recommend", @"mute"]) {
        if ([lower rangeOfString:no].location != NSNotFound) return NO;
    }
    return YES;
}

static NSDictionary* JSONDictionaryFromString(NSString* s) {
    NSData* d = [s dataUsingEncoding:NSUTF8StringEncoding];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    return [j isKindOfClass:[NSDictionary class]] ? j : nil;
}

NSDictionary* NFBLSVariables(NSURL* url, NSData* body) {
    NSURLComponents* comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem* item in comps.queryItems) {
        if ([item.name isEqualToString:@"variables"] && item.value.length) {
            NSDictionary* v = JSONDictionaryFromString(item.value);
            if (v) return v;
        }
    }
    id j = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![j isKindOfClass:[NSDictionary class]]) return nil;
    id v = [(NSDictionary*)j objectForKey:@"variables"];
    if ([v isKindOfClass:[NSString class]]) return JSONDictionaryFromString(v);
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

NSString* NFBLSListID(NSDictionary* v) {
    for (NSString* k in @[@"listId", @"list_id", @"listID", @"rest_id", @"id"]) {
        NSString* s = S(v, k);
        if (s.length) return s;
    }
    return nil;
}

// Percent-encode everything but unreserved characters, as X's own clients do for JSON in a query.
static NSString* EncodeQueryValue(NSString* s) {
    NSMutableCharacterSet* allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

NSMutableURLRequest* NFBLSRequestWithVariable(NSURLRequest* request, NSData* body, NSString* key, id value) {
    NSMutableURLRequest* out = [request mutableCopy];
    // The query is rebuilt by hand, leaving every other parameter byte for byte as X sent it
    // (URL component APIs re-encode, and differ between platforms in how).
    NSString* url = request.URL.absoluteString;
    NSRange q = [url rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        NSString* head = [url substringToIndex:q.location];
        NSString* query = [url substringFromIndex:q.location + 1];
        NSString* fragment = nil;
        NSRange hash = [query rangeOfString:@"#"];
        if (hash.location != NSNotFound) {
            fragment = [query substringFromIndex:hash.location];
            query = [query substringToIndex:hash.location];
        }
        NSMutableArray* parts = [[query componentsSeparatedByString:@"&"] mutableCopy];
        for (NSUInteger i = 0; i < parts.count; i++) {
            if (![parts[i] hasPrefix:@"variables="]) continue;
            NSMutableDictionary* vars = [NFBLSVariables(request.URL, nil) mutableCopy] ?: [NSMutableDictionary dictionary];
            if (value) vars[key] = value;
            else [vars removeObjectForKey:key];
            NSData* d = [NSJSONSerialization dataWithJSONObject:vars options:0 error:NULL];
            NSString* js = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            parts[i] = [@"variables=" stringByAppendingString:EncodeQueryValue(js)];
            NSString* rebuilt = [NSString stringWithFormat:@"%@?%@%@", head, [parts componentsJoinedByString:@"&"], fragment ?: @""];
            out.URL = [NSURL URLWithString:rebuilt];
            if (body.length) out.HTTPBody = body;
            return out.URL ? out : nil;
        }
    }
    id j = body.length ? [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:NULL] : nil;
    if ([j isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary* root = j;
        id v = root[@"variables"];
        BOOL asString = [v isKindOfClass:[NSString class]];
        NSMutableDictionary* vars = asString ? [JSONDictionaryFromString(v) mutableCopy]
                                             : ([v isKindOfClass:[NSMutableDictionary class]] ? v : nil);
        if (!vars) vars = [NSMutableDictionary dictionary];
        if (value) vars[key] = value;
        else [vars removeObjectForKey:key];
        if (asString) {
            NSData* d = [NSJSONSerialization dataWithJSONObject:vars options:0 error:NULL];
            root[@"variables"] = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        } else {
            root[@"variables"] = vars;
        }
        NSData* newBody = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
        out.HTTPBodyStream = nil; // the body and the stream exclude each other: clear the stream first
        out.HTTPBody = newBody;
        [out setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
        return out;
    }
    return nil; // no variables anywhere: nothing we can page
}

#pragma mark - Diagnostics

static NSArray* KeysOf(id node) {
    return [node isKindOfClass:[NSDictionary class]] ? [[(NSDictionary*)node allKeys] sortedArrayUsingSelector:@selector(compare:)] : @[];
}

// The key path from the top of the response down to the instruction list.
static BOOL PathTo(id node, id target, NSMutableArray* path, int depth) {
    if (node == target) return YES;
    if (depth > 12) return NO;
    if ([node isKindOfClass:[NSDictionary class]]) {
        for (NSString* k in KeysOf(node)) {
            [path addObject:k];
            if (PathTo([(NSDictionary*)node objectForKey:k], target, path, depth + 1)) return YES;
            [path removeLastObject];
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        NSArray* a = node;
        for (NSUInteger i = 0; i < a.count; i++) {
            [path addObject:[NSString stringWithFormat:@"[%lu]", (unsigned long)i]];
            if (PathTo(a[i], target, path, depth + 1)) return YES;
            [path removeLastObject];
        }
    }
    return NO;
}

NSDictionary* NFBLSShape(id json) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    [out setObject:KeysOf(json) forKey:@"top"];
    NSArray* ins = NFBLSInstructions(json);
    if (!ins) {
        [out setObject:@"no instructions found" forKey:@"instructions"];
        return out;
    }
    NSMutableArray* path = [NSMutableArray array];
    if (PathTo(json, ins, path, 0)) [out setObject:[path componentsJoinedByString:@"."] forKey:@"path"];
    NSMutableArray* types = [NSMutableArray array];
    for (id i in ins)
        [types addObject:(S(i, @"type") ?: S(i, @"__typename") ?
                                                               : @"?")];
    [out setObject:types forKey:@"instructions"];
    NSDictionary* add = NFBLSAddEntries(json);
    NSMutableDictionary* kinds = [NSMutableDictionary dictionary];
    for (id e in (NSArray*)[add objectForKey:@"entries"]) {
        NSDictionary* c = D(e, @"content");
        NSString* t = TypeOf(c) ?: @"?";
        if ([kinds objectForKey:t]) continue;
        NSMutableDictionary* k = [NSMutableDictionary dictionary];
        [k setObject:KeysOf(e) forKey:@"entry"];
        [k setObject:KeysOf(c) forKey:@"content"];
        NSDictionary* ic = D(c, @"itemContent");
        if (ic) [k setObject:KeysOf(ic) forKey:@"itemContent"];
        NSDictionary* r = TweetResult(e);
        if (r) {
            [k setObject:KeysOf(r) forKey:@"result"];
            [k setObject:KeysOf(D(r, @"legacy")) forKey:@"legacy"];
        }
        if ([t isEqualToString:@"TimelineTimelineCursor"]) [k setObject:(CursorType(c) ?: @"?") forKey:@"cursorType"];
        [kinds setObject:k forKey:t];
    }
    [out setObject:kinds forKey:@"entryKinds"];
    NSDictionary* split = NFBLSSplit(json);
    [out setObject:@([(NSArray*)[split objectForKey:@"items"] count]) forKey:@"posts"];
    [out setObject:@([split objectForKey:@"bottom"] != nil) forKey:@"hasBottomCursor"];
    return out;
}
