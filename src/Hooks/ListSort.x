//
//  ListSort.x
//  NeoFreeBird
//
//  Popular order for lists, like the Following tab. Ported from the x-list-sort userscript.
//
//  How it works: when a list opens with Popular on, X's request for the list's first page is
//  answered here. The same request is sent on with X's own cursor, page after page, until the
//  posts reach back to the chosen time window. The posts are then ranked (src/ListSort/
//  NFBListSortEngine.m) and handed to X in pages of 20, in X's own response format, so X draws
//  them itself: videos, likes and menus all work as usual. A cursor of ours ("NFB|40") asks for
//  the next page of the ranking. The scan is saved and re-sorted when settings change; Rescan
//  (or "Forget saved scans") loads fresh counts.
//
//  Nothing is changed while Popular is off. Only X's list timeline requests are looked at.
//

#import "HookHelpers.h"
#import "ListSort/NFBListSort.h"
#import "ListSort/NFBListSortEngine.h"

static NSString* const NFBLSPassThroughKey = @"NFBListSortPassThrough";
static NSString* const NFBLSProgressNote = @"NFBListSortProgress"; // userInfo: listId, count
static NSString* const NFBLSDoneNote = @"NFBListSortDone";         // userInfo: listId, lines
static NSString* const NFBLSSettingsNote = @"NFBListSortSettingsChanged";
static const NSUInteger NFBLSPageSize = 20;
static const NSInteger NFBLSBigPage = 100; // posts asked for per page while scanning (X's own requests ask for fewer)
static const int64_t NFBLSKeepAliveSeconds = 4;

// Public web bearer token (the same one LocationLabels.x uses; ships in the web client).
static NSString* const NFBLSWebBearer = @"Bearer "
                                        @"AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puT"
                                        @"s%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

// MARK: - Settings

NSArray<NSArray*>* NFBListSortMetricChoices(void) {
    return @[@[@0, @"Likes"], @[@1, @"Reposts"], @[@2, @"Replies"], @[@3, @"Views"],
             @[@4, @"Likes + 2× reposts + replies"], @[@5, @"Engagement rate"], @[@6, @"Newest first"]];
}

NSArray<NSArray*>* NFBListSortWindowChoices(void) {
    return @[@[@6, @"Last 6 hours"], @[@24, @"Last 24 hours"], @[@72, @"Last 3 days"],
             @[@168, @"Last 7 days"], @[@720, @"Last 30 days"], @[@0, @"As far as it loads"]];
}

NSArray<NSArray*>* NFBListSortShowChoices(void) {
    return @[@[@0, @"All posts"], @[@1, @"Videos"], @[@2, @"Pictures"], @[@3, @"Videos or pictures"]];
}

NSString* NFBListSortLabelFor(NSArray<NSArray*>* choices, NSInteger value) {
    for (NSArray* c in choices) {
        if ([c[0] integerValue] == value) return c[1];
    }
    return [choices.firstObject lastObject];
}

NSDictionary* NFBListSortCurrentSettings(void) {
    return @{
        @"metric": @([BHTSettings integerForKey:NFBLSKeyMetric]),
        @"window": @([BHTSettings integerForKey:NFBLSKeyTimeWindow]),
        @"show": @([BHTSettings integerForKey:NFBLSKeyShow]),
        @"reposts": @([BHTSettings boolForKey:NFBLSKeyReposts]),
        @"onePerAccount": @([BHTSettings boolForKey:NFBLSKeyOnePerAccount]),
    };
}

static BOOL NFBLSPopular(void) {
    return [BHTSettings boolForKey:NFBLSKeyPopular];
}

// MARK: - State (all on one serial queue)

static dispatch_queue_t NFBLSQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.neofreebird.listsort", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static NSMutableDictionary<NSString*, NSMutableDictionary*>* gScans; // listId -> saved scan
static NSMutableDictionary<NSString*, id>* gScanning;                // listId -> the scan running for it
static NSMutableSet<NSString*>* gForced;                             // lists to scan again next time
static NSMutableSet<NSString*>* gStopping;                           // scans you asked to stop
static NSMutableArray<NSString*>* gEvents;                           // diagnostics log
static NSMutableOrderedSet<NSString*>* gOps;                         // GraphQL operations seen
static NSDictionary* gLastShape;
static NSString* gButtonHost;

static void NFBLSSetUpState(void) {
    gScans = [NSMutableDictionary dictionary];
    gScanning = [NSMutableDictionary dictionary];
    gForced = [NSMutableSet set];
    gStopping = [NSMutableSet set];
    gEvents = [NSMutableArray array];
    gOps = [NSMutableOrderedSet orderedSet];
}

// A list id, shortened for the log.
static NSString* NFBLSShortID(NSString* listId) {
    return listId.length > 4 ? [@"…" stringByAppendingString:[listId substringFromIndex:listId.length - 4]] : (listId ?: @"?");
}

// Call on the queue.
static void NFBLSEvent(NSString* text) {
    static NSDateFormatter* f;
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"HH:mm:ss";
    }
    [gEvents addObject:[NSString stringWithFormat:@"%@ %@", [f stringFromDate:[NSDate date]], text]];
    if (gEvents.count > 60) [gEvents removeObjectAtIndex:0];
}

static void NFBLSPost(NSString* name, NSDictionary* info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:info];
    });
}

// MARK: - Saved scans

static NSString* NFBLSCacheDir(void) {
    NSString* base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    return [[base stringByAppendingPathComponent:@"NeoFreeBird"] stringByAppendingPathComponent:@"ListSort"];
}

static NSString* NFBLSCachePath(NSString* listId) {
    NSCharacterSet* bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString* safe = [[listId componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    return [NFBLSCacheDir() stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"json"]];
}

static NSArray* NFBLSItemsFromEntries(NSArray* entries) {
    NSMutableArray* items = [NSMutableArray array];
    for (id e in entries) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary* s = NFBLSStats(e);
        if (s) [items addObject:@{@"entry": e, @"stats": s}];
    }
    return items;
}

// Call on the queue.
static void NFBLSSaveScan(NSString* listId, NSDictionary* rec) {
    NSMutableArray* entries = [NSMutableArray array];
    for (NSDictionary* it in rec[@"items"])
        [entries addObject:it[@"entry"]];
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    for (NSString* k in @[@"savedAt", @"windowHours", @"complete", @"oldest", @"stopped", @"template", @"cursorEntry", @"headers"]) {
        if (rec[k]) out[k] = rec[k];
    }
    out[@"entries"] = entries;
    NSData* data = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    if (!data) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:NFBLSCacheDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:NFBLSCachePath(listId) atomically:YES];
}

// Call on the queue. The scan for a list, from memory or from disk.
static NSMutableDictionary* NFBLSScanFor(NSString* listId) {
    if (!listId) return nil;
    NSMutableDictionary* rec = gScans[listId];
    if (rec) return rec;
    NSData* data = [NSData dataWithContentsOfFile:NFBLSCachePath(listId)];
    id saved = NFBLSParse(data);
    if (![saved isKindOfClass:[NSDictionary class]] || !saved[@"template"]) return nil;
    rec = [saved mutableCopy];
    rec[@"items"] = NFBLSItemsFromEntries(saved[@"entries"]);
    [rec removeObjectForKey:@"entries"];
    gScans[listId] = rec;
    return rec;
}

// A scan has the posts for a window if it went back past the window's start, or to the end.
static BOOL NFBLSCovers(NSDictionary* rec, NSInteger windowHours) {
    if (!rec) return NO;
    if ([rec[@"complete"] boolValue]) return YES;
    if (windowHours <= 0) return NO;
    double oldest = [rec[@"oldest"] doubleValue];
    return oldest > 0 && oldest <= [[NSDate date] timeIntervalSince1970] - windowHours * 3600.0;
}

// Call on the queue. The ranked posts for the current settings (re-sorted only when they change).
static NSArray* NFBLSRanked(NSMutableDictionary* rec) {
    NSDictionary* settings = NFBListSortCurrentSettings();
    if (rec[@"ranked"] && [rec[@"rankedFor"] isEqual:settings]) return rec[@"ranked"];
    NSDictionary* sorted = NFBLSSort(rec[@"items"], settings, [[NSDate date] timeIntervalSince1970]);
    rec[@"ranked"] = sorted[@"pool"];
    rec[@"rankedFor"] = settings;
    rec[@"breakdown"] = sorted[@"breakdown"];
    return sorted[@"pool"];
}

static NSArray<NSString*>* NFBLSSummaryLines(NSMutableDictionary* rec) {
    NFBLSRanked(rec);
    NSMutableArray* lines = [NFBLSDescribe(rec[@"breakdown"], NFBListSortCurrentSettings(), rec[@"stopped"]) mutableCopy];
    double saved = [rec[@"savedAt"] doubleValue];
    if (saved > 0) {
        long mins = (long)(([[NSDate date] timeIntervalSince1970] - saved) / 60);
        [lines addObject:mins < 1 ? @"Scanned just now." : mins < 60    ? [NSString stringWithFormat:@"Scanned %ld min ago.", mins]
                                                       : mins < 48 * 60 ? [NSString stringWithFormat:@"Scanned %ld h ago.", mins / 60]
                                                                        : [NSString stringWithFormat:@"Scanned %ld days ago.", mins / 1440]];
    }
    return lines;
}

void NFBListSortForgetScans(void) {
    dispatch_async(NFBLSQueue(), ^{
        [gScans removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:NFBLSCacheDir() error:nil];
        NFBLSEvent(@"saved scans forgotten");
    });
}

// MARK: - Diagnostics

static NSString* NFBLSAuthKind(NSURLRequest* r) {
    NSString* a = [r valueForHTTPHeaderField:@"Authorization"] ?: @"";
    if ([a containsString:@"oauth_token="] || [a hasPrefix:@"OAuth "]) return @"oauth1";
    if ([a hasPrefix:@"Bearer"]) return @"bearer";
    return a.length ? @"other" : @"none";
}

static NSString* NFBLSVariablesPlace(NSURLRequest* r) {
    if ([r.URL.query containsString:@"variables="]) return @"query";
    if (r.HTTPBody.length) return @"body";
    if (r.HTTPBodyStream) return @"stream";
    return @"none";
}

NSString* NFBListSortDiagnostics(void) {
    __block NSString* text = nil;
    dispatch_sync(NFBLSQueue(), ^{
        NSMutableDictionary* lists = [NSMutableDictionary dictionary];
        for (NSString* listId in gScans) {
            NSDictionary* rec = gScans[listId];
            lists[NFBLSShortID(listId)] = @{@"posts": @([rec[@"items"] count]),
                                            @"complete": rec[@"complete"] ?: @NO,
                                            @"stopped": rec[@"stopped"] ?: @""};
        }
        NSMutableDictionary* d = [NSMutableDictionary dictionary];
#ifdef NFB_VERSION_STRING
        d[@"version"] = @NFB_VERSION_STRING;
#endif
        d[@"listSort"] = @"1";
        d[@"popular"] = @(NFBLSPopular());
        d[@"settings"] = NFBListSortCurrentSettings();
        d[@"operations"] = gOps.array;
        d[@"events"] = gEvents;
        d[@"lastShape"] = gLastShape ?: @"none yet";
        d[@"buttonHost"] = gButtonHost ?: @"none yet";
        d[@"scans"] = lists;
        NSData* data = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
        text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    });
    return text;
}

// MARK: - The URL protocol

static NSData* NFBLSBodyOf(NSURLRequest* request) {
    if (request.HTTPBody) return request.HTTPBody;
    NSInputStream* stream = request.HTTPBodyStream;
    if (!stream) return nil;
    NSMutableData* data = [NSMutableData data];
    [stream open];
    uint8_t buffer[16384];
    NSInteger n;
    while ((n = [stream read:buffer maxLength:sizeof buffer]) > 0)
        [data appendBytes:buffer length:(NSUInteger)n];
    [stream close];
    return data;
}

// The response headers worth passing on with data we make (not lengths or encodings: ours differ).
static NSDictionary* NFBLSCleanHeaders(NSDictionary* headers) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    for (NSString* k in headers) {
        NSString* lower = [k lowercaseString];
        if ([lower isEqualToString:@"content-length"] || [lower isEqualToString:@"content-encoding"] ||
            [lower isEqualToString:@"transfer-encoding"]) continue;
        out[k] = headers[k];
    }
    BOOL hasType = NO;
    for (NSString* k in out)
        if ([[k lowercaseString] isEqualToString:@"content-type"]) hasType = YES;
    if (!hasType) out[@"Content-Type"] = @"application/json; charset=utf-8";
    return out;
}

static void NFBLSNoteListSeen(NSString* listId);

// A private session whose callbacks run on our queue, so all state is touched in one place.
static NSURLSession* NFBLSSession(void) {
    static NSURLSession* session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration* c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.protocolClasses = @[];
        c.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        c.timeoutIntervalForRequest = 30;
        NSOperationQueue* oq = [[NSOperationQueue alloc] init];
        oq.maxConcurrentOperationCount = 1;
        oq.underlyingQueue = NFBLSQueue();
        session = [NSURLSession sessionWithConfiguration:c delegate:nil delegateQueue:oq];
    });
    return session;
}

// Sends a request past our own protocol. The completion runs on our queue.
static NSURLSessionDataTask* NFBLSFetch(NSURLRequest* request, void (^done)(NSData*, NSHTTPURLResponse*, NSError*)) {
    NSMutableURLRequest* r = [request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:NFBLSPassThroughKey inRequest:r];
    NSURLSessionDataTask* task = [NFBLSSession() dataTaskWithRequest:r
                                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                                       done(data, [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil, error);
                                                   }];
    [task resume];
    return task;
}

static BOOL NFBLSHaveWebSession(void) {
    NSDictionary* credentials = currentWebCredentials();
    return [credentials[@"auth_token"] length] > 0 && [credentials[@"ct0"] length] > 0;
}

// The same request, signed in with NeoFreeBird's web session instead (for when X refuses a
// changed native request). Only used if a web session already exists.
static NSMutableURLRequest* NFBLSWithWebAuth(NSMutableURLRequest* r) {
    NSDictionary* credentials = currentWebCredentials();
    NSString* authToken = credentials[@"auth_token"];
    NSString* ct0 = credentials[@"ct0"];
    if (authToken.length == 0 || ct0.length == 0) return r;
    [r setValue:nil forHTTPHeaderField:@"Authorization"];
    [r setValue:NFBLSWebBearer forHTTPHeaderField:@"authorization"];
    [r setValue:@"OAuth2Session" forHTTPHeaderField:@"x-twitter-auth-type"];
    [r setValue:ct0 forHTTPHeaderField:@"x-csrf-token"];
    [r setValue:[NSString stringWithFormat:@"auth_token=%@; ct0=%@", authToken, ct0] forHTTPHeaderField:@"Cookie"];
    r.HTTPShouldHandleCookies = NO;
    return r;
}

@class NFBListSortURLProtocol;

@protocol NFBLSWaiter <NSObject>
- (void)serveFirstPageOf:(NSMutableDictionary*)rec;
@end

// One scan of one list. It belongs to no request: if you leave the list while it runs, it still
// finishes and is saved, and opening the list again waits for it instead of starting another.
@interface NFBLSScanner : NSObject
@end

@implementation NFBLSScanner {
    NSString* _listId;
    NSURLRequest* _request; // X's own first-page request, the one each page is asked for with
    NSData* _body;
    NSMutableDictionary* _scan;
    NSMutableArray* _waiters;
}

- (instancetype)initWithList:(NSString*)listId request:(NSURLRequest*)request body:(NSData*)body
                   firstPage:(id)json
                       split:(NSDictionary*)split
                     headers:(NSDictionary*)headers
                      window:(NSInteger)window {
    if ((self = [super init])) {
        _listId = listId;
        _request = request;
        _body = body;
        _waiters = [NSMutableArray array];
        _scan = [NSMutableDictionary dictionary];
        _scan[@"template"] = json;
        if (split[@"cursorEntry"]) _scan[@"cursorEntry"] = split[@"cursorEntry"];
        _scan[@"headers"] = headers ?: @{};
        _scan[@"items"] = [split[@"items"] mutableCopy];
        _scan[@"seen"] = [NSMutableSet setWithArray:[split[@"items"] valueForKeyPath:@"stats.id"]];
        _scan[@"pages"] = @1;
        if (split[@"bottom"]) _scan[@"bottom"] = split[@"bottom"];
        _scan[@"windowHours"] = @(window);
        NSInteger ownCount = [NFBLSVariables(request.URL, body)[@"count"] integerValue];
        _scan[@"bigPages"] = @(ownCount > 0 && ownCount < NFBLSBigPage);
    }
    return self;
}

- (void)addWaiter:(id<NFBLSWaiter>)waiter {
    [_waiters addObject:waiter];
}

- (void)step {
    NSMutableDictionary* scan = _scan;
    double oldest = 0;
    for (NSDictionary* it in scan[@"items"]) {
        double t = [it[@"stats"][@"ts"] doubleValue];
        if (t > 0) oldest = oldest > 0 ? MIN(oldest, t) : t;
    }
    scan[@"oldest"] = @(oldest);
    NSInteger window = [scan[@"windowHours"] integerValue];
    NSInteger pages = [scan[@"pages"] integerValue];
    NSString* bottom = scan[@"bottom"];
    if (!bottom.length) {
        scan[@"complete"] = @YES;
        scan[@"stopped"] = @"Reached the end of the list.";
        [self finish];
        return;
    }
    if (window > 0 && oldest > 0 && oldest < [[NSDate date] timeIntervalSince1970] - window * 3600.0) {
        [self finish];
        return;
    }
    // No page limit: it runs until the window is covered, the list ends, X stops answering, or you
    // press Stop scanning on the list button.
    if ([gStopping containsObject:_listId]) {
        [gStopping removeObject:_listId];
        scan[@"stopped"] = @"Stopped by you.";
        [self finish];
        return;
    }
    NSMutableURLRequest* r = NFBLSRequestWithVariable(_request, _body, @"cursor", bottom);
    if (!r) {
        scan[@"stopped"] = @"This list's request has no cursor to page with.";
        [self finish];
        return;
    }
    // Fewer, bigger pages, unless X refuses them.
    BOOL big = [scan[@"bigPages"] boolValue];
    if (big) r = NFBLSRequestWithVariable(r, r.HTTPBody, @"count", @(NFBLSBigPage)) ?: r;
    if ([scan[@"webAuth"] boolValue]) r = NFBLSWithWebAuth(r);
    NFBLSFetch(r, ^(NSData* data, NSHTTPURLResponse* http, NSError* error) {
        if (big && !error && http.statusCode != 200) {
            NFBLSEvent([NSString stringWithFormat:@"  pages of %ld refused (%ld): back to X's own page size", (long)NFBLSBigPage, (long)http.statusCode]);
            scan[@"bigPages"] = @NO;
            [self step];
            return;
        }
        if (error || http.statusCode != 200) {
            NSInteger code = http.statusCode;
            if ((code == 401 || code == 403) && ![scan[@"triedWeb"] boolValue] && NFBLSHaveWebSession()) {
                scan[@"triedWeb"] = @YES;
                scan[@"webAuth"] = @YES;
                NFBLSEvent([NSString stringWithFormat:@"  page %ld refused (%ld), trying the web session", (long)pages + 1, (long)code]);
                [self step];
                return;
            }
            NSString* why = error ? error.localizedDescription : [NSString stringWithFormat:@"%ld", (long)code];
            scan[@"stopped"] = [NSString stringWithFormat:@"X refused page %ld (%@).", (long)pages + 1, why];
            NFBLSEvent([@"  " stringByAppendingString:scan[@"stopped"]]);
            [self finish];
            return;
        }
        NSDictionary* split = NFBLSSplit(NFBLSParse(data));
        NSMutableSet* seen = scan[@"seen"];
        NSMutableArray* all = scan[@"items"];
        NSUInteger added = 0;
        for (NSDictionary* it in split[@"items"]) {
            NSString* ident = it[@"stats"][@"id"];
            if ([seen containsObject:ident]) continue;
            [seen addObject:ident];
            [all addObject:it];
            added++;
        }
        scan[@"pages"] = @(pages + 1);
        NFBLSPost(NFBLSProgressNote, @{@"listId": self->_listId ?: @"?",
                                       @"count": @(all.count)});
        NSString* next = split[@"bottom"];
        if (added == 0 || !next.length || [next isEqualToString:bottom]) {
            scan[@"complete"] = @YES;
            scan[@"stopped"] = @"Reached the end of the list.";
            [scan removeObjectForKey:@"bottom"];
            [self finish];
            return;
        }
        scan[@"bottom"] = next;
        [self step];
    });
}

- (void)finish {
    NSMutableDictionary* rec = [NSMutableDictionary dictionary];
    for (NSString* k in @[@"template", @"cursorEntry", @"headers", @"items", @"complete", @"oldest", @"stopped", @"windowHours"]) {
        if (_scan[k]) rec[k] = _scan[k];
    }
    rec[@"savedAt"] = @([[NSDate date] timeIntervalSince1970]);
    gScans[_listId] = rec;
    NFBLSSaveScan(_listId, rec);
    NFBLSEvent([NSString stringWithFormat:@"  scan of list %@ done: %lu posts in %@ pages. %@", NFBLSShortID(_listId),
                                          (unsigned long)[rec[@"items"] count], _scan[@"pages"], rec[@"stopped"] ?: @""]);
    NFBLSPost(NFBLSDoneNote, @{@"listId": _listId ?: @"?", @"lines": NFBLSSummaryLines(rec)});
    [gScanning removeObjectForKey:_listId];
    for (id<NFBLSWaiter> w in _waiters)
        [w serveFirstPageOf:rec];
    [_waiters removeAllObjects];
}

@end

@interface NFBListSortURLProtocol : NSURLProtocol <NFBLSWaiter>
@end

@implementation NFBListSortURLProtocol {
    NSURLSessionDataTask* _task;
    NSData* _body;
    NSString* _listId;
    BOOL _stopped;
    BOOL _sentHeader;
    BOOL _finished;
    dispatch_source_t _keepAlive;
}

+ (BOOL)canInitWithRequest:(NSURLRequest*)request {
    if ([NSURLProtocol propertyForKey:NFBLSPassThroughKey inRequest:request]) return NO;
    NSString* op = NFBLSOperationName(request.URL);
    if (!op) return NO;
    BOOL isList = NFBLSIsListTimelineOperation(op);
    NSString* method = request.HTTPMethod ?: @"GET";
    dispatch_async(NFBLSQueue(), ^{
        // Which operations X uses, so a list timeline under an unexpected name can be found.
        NSString* name = [NSString stringWithFormat:@"%@ %@%@", method, op, isList ? @" (list timeline)" : @""];
        if (![gOps containsObject:name]) {
            [gOps addObject:name];
            if (gOps.count > 80) [gOps removeObjectAtIndex:0];
        }
    });
    if (!isList) return NO;
    NSDictionary* vars = NFBLSVariables(request.URL, request.HTTPBody);
    NFBLSNoteListSeen(NFBLSListID(vars) ?: @"?");
    if (NFBLSOffsetOfCursor(vars[@"cursor"]) >= 0) return YES; // our own cursor: always ours to answer
    return NFBLSPopular();
}

+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request {
    return request;
}

- (void)startLoading {
    NSData* body = NFBLSBodyOf(self.request);
    dispatch_async(NFBLSQueue(), ^{
        [self beginWithBody:body];
    });
}

- (void)stopLoading {
    dispatch_async(NFBLSQueue(), ^{
        self->_stopped = YES;
        [self->_task cancel];
        self->_task = nil;
        [self stopKeepAlive];
    });
}

// MARK: Sending to X

- (void)sendHeaderWith:(NSDictionary*)headers {
    if (_sentHeader || _stopped) return;
    _sentHeader = YES;
    NSHTTPURLResponse* r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                       statusCode:200
                                                      HTTPVersion:@"HTTP/1.1"
                                                     headerFields:NFBLSCleanHeaders(headers)];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}

- (void)deliver:(NSData*)data headers:(NSDictionary*)headers {
    if (_stopped || _finished) return;
    _finished = YES;
    [self stopKeepAlive];
    [self sendHeaderWith:headers];
    if (data.length) [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)deliverRaw:(NSData*)data response:(NSURLResponse*)response {
    if (_stopped || _finished) return;
    _finished = YES;
    [self stopKeepAlive];
    if (!_sentHeader) [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (data.length) [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)fail:(NSError*)error {
    if (_stopped || _finished) return;
    _finished = YES;
    [self stopKeepAlive];
    [self.client URLProtocol:self didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil]];
}

// While a scan runs, a space every few seconds keeps X's request from timing out.
// Spaces before JSON are allowed, so the final answer still reads as normal.
- (void)startKeepAliveWith:(NSDictionary*)headers {
    [self sendHeaderWith:headers];
    if (_keepAlive) return;
    _keepAlive = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, NFBLSQueue());
    dispatch_source_set_timer(_keepAlive, dispatch_time(DISPATCH_TIME_NOW, NFBLSKeepAliveSeconds * NSEC_PER_SEC),
                              NFBLSKeepAliveSeconds * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(_keepAlive, ^{
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self->_stopped || self->_finished) return;
        [self.client URLProtocol:self didLoadData:[@" " dataUsingEncoding:NSUTF8StringEncoding]];
    });
    dispatch_resume(_keepAlive);
}

- (void)stopKeepAlive {
    if (_keepAlive) {
        dispatch_source_cancel(_keepAlive);
        _keepAlive = nil;
    }
}

// MARK: The flow

- (NSMutableURLRequest*)originalRequest {
    NSMutableURLRequest* r = [self.request mutableCopy];
    if (_body.length && !r.HTTPBody) {
        r.HTTPBodyStream = nil;
        r.HTTPBody = _body;
    }
    return r;
}

- (void)fetch:(NSURLRequest*)request done:(void (^)(NSData*, NSHTTPURLResponse*, NSError*))done {
    __weak __typeof__(self) weakSelf = self;
    _task = NFBLSFetch(request, ^(NSData* data, NSHTTPURLResponse* http, NSError* error) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self->_stopped) return;
        self->_task = nil;
        done(data, http, error);
    });
}

- (void)beginWithBody:(NSData*)body {
    if (_stopped) return;
    _body = body;
    NSDictionary* vars = NFBLSVariables(self.request.URL, body);
    _listId = NFBLSListID(vars) ?: @"?";
    id cursor = vars[@"cursor"];
    NSInteger offset = NFBLSOffsetOfCursor(cursor);
    NFBLSEvent([NSString stringWithFormat:@"list %@: %@ %@, variables in %@, auth %@, cursor %@, %@",
                                          NFBLSShortID(_listId), self.request.HTTPMethod ?: @"GET", NFBLSOperationName(self.request.URL),
                                          NFBLSVariablesPlace(self.request), NFBLSAuthKind(self.request),
                                          offset >= 0 ? [NSString stringWithFormat:@"ours (%ld)", (long)offset] : (cursor ? @"X's" : @"none"),
                                          NFBLSPopular() ? @"Popular" : @"Latest"]);
    if (offset >= 0) {
        [self serveFrom:offset];
        return;
    }
    if ([_listId isEqualToString:@"?"]) {
        // Without the list's id a scan could not be told apart from other lists' scans.
        NFBLSEvent(@"  no list id in the request: left alone");
        [self passThrough:[self originalRequest]];
        return;
    }
    if (!NFBLSPopular()) {
        [self passThrough:[self originalRequest]];
        return;
    }
    [self firstPage];
}

- (void)passThrough:(NSURLRequest*)request {
    [self fetch:request
           done:^(NSData* data, NSHTTPURLResponse* http, NSError* error) {
               if (error || !http) [self fail:error];
               else [self deliverRaw:data response:http];
           }];
}

// A later page of the ranking.
- (void)serveFrom:(NSInteger)offset {
    NSMutableDictionary* rec = NFBLSScanFor(_listId);
    if (!NFBLSPopular() || !rec) {
        // Not sorting any more (or the scan is gone): carry on with X's own timeline from the top.
        NFBLSEvent(@"  our cursor but no ranking to continue: X's own page instead");
        NSMutableURLRequest* r = NFBLSRequestWithVariable([self originalRequest], _body, @"cursor", nil);
        [self passThrough:r ?: [self originalRequest]];
        return;
    }
    NSData* page = NFBLSPage(rec[@"template"], NFBLSRanked(rec), (NSUInteger)offset, NFBLSPageSize, rec[@"cursorEntry"], NO);
    if (!page) {
        [self passThrough:[self originalRequest]];
        return;
    }
    [self deliver:page headers:rec[@"headers"]];
}

// The first page: the saved scan if it covers the window, otherwise a scan. Always from the top
// of the list: X may be asking with a cursor of its own (pull to refresh, or scrolling on in a
// list that was opened before Popular was switched on), and a ranking starts from the newest post.
- (void)firstPage {
    NSMutableURLRequest* original = [self originalRequest];
    NSMutableURLRequest* top = original;
    if (NFBLSVariables(original.URL, _body)[@"cursor"]) top = NFBLSRequestWithVariable(original, _body, @"cursor", nil) ?: original;
    [self fetch:top
           done:^(NSData* data, NSHTTPURLResponse* http, NSError* error) {
               if (top != original && (http.statusCode == 401 || http.statusCode == 403)) {
                   // X would not take the request without its cursor (a signed request cannot be changed):
                   // answer this one as X would, untouched.
                   NFBLSEvent([NSString stringWithFormat:@"  X refused the request without its cursor (%ld): left alone", (long)http.statusCode]);
                   [self passThrough:original];
                   return;
               }
               [self handleFirstPage:data response:http error:error];
           }];
}

- (void)handleFirstPage:(NSData*)data response:(NSHTTPURLResponse*)http error:(NSError*)error {
    {
        if (error || !http) {
            [self fail:error];
            return;
        }
        if (http.statusCode != 200) {
            NFBLSEvent([NSString stringWithFormat:@"  X answered %ld: left alone", (long)http.statusCode]);
            [self deliverRaw:data response:http];
            return;
        }
        id json = NFBLSParse(data);
        NSMutableDictionary* shape = [NFBLSShape(json) mutableCopy];
        shape[@"operation"] = NFBLSOperationName(self.request.URL) ?: @"?";
        gLastShape = shape;
        if (!NFBLSAddEntries(json)) {
            NFBLSEvent(@"  response not in the expected shape (see lastShape): left alone");
            [self deliverRaw:data response:http];
            return;
        }
        NSDictionary* split = NFBLSSplit(json);
        NSString* listId = self->_listId;
        NSInteger window = [BHTSettings integerForKey:NFBLSKeyTimeWindow];
        NSMutableDictionary* rec = NFBLSScanFor(listId);
        BOOL forced = [gForced containsObject:listId];
        if (rec && !forced && NFBLSCovers(rec, window)) {
            // Re-sort the saved scan. This fresh response is the shape to answer in, and posts that
            // are new since the scan are added, so a reopened list has the latest ones too.
            rec[@"template"] = json;
            if (split[@"cursorEntry"]) rec[@"cursorEntry"] = split[@"cursorEntry"];
            rec[@"headers"] = http.allHeaderFields ?: @{};
            NSMutableSet* have = [NSMutableSet set];
            for (NSDictionary* it in rec[@"items"])
                [have addObject:it[@"stats"][@"id"]];
            NSMutableArray* items = [rec[@"items"] mutableCopy];
            NSUInteger added = 0;
            for (NSDictionary* it in split[@"items"]) {
                if ([have containsObject:it[@"stats"][@"id"]]) continue;
                [items addObject:it];
                added++;
            }
            if (added) {
                rec[@"items"] = items;
                [rec removeObjectForKey:@"ranked"];
            }
            NFBLSEvent([NSString stringWithFormat:@"  re-sorted the saved scan (%lu posts, %lu new)", (unsigned long)items.count, (unsigned long)added]);
            [self serveFirstPageOf:rec];
            return;
        }
        [self startKeepAliveWith:http.allHeaderFields];
        NFBLSScanner* scanner = gScanning[listId];
        if (scanner) {
            NFBLSEvent(@"  a scan of this list is already running: waiting for it");
            [scanner addWaiter:self];
            return;
        }
        [gForced removeObject:listId];
        scanner = [[NFBLSScanner alloc] initWithList:listId
                                             request:[self originalRequest]
                                                body:self->_body
                                           firstPage:json
                                               split:split
                                             headers:http.allHeaderFields
                                              window:window];
        gScanning[listId] = scanner;
        [scanner addWaiter:self];
        NFBLSEvent([NSString stringWithFormat:@"  scanning (%@)", NFBListSortLabelFor(NFBListSortWindowChoices(), window)]);
        [scanner step];
    }
}

- (void)serveFirstPageOf:(NSMutableDictionary*)rec {
    if (_stopped || _finished) return;
    NSData* page = NFBLSPage(rec[@"template"], NFBLSRanked(rec), 0, NFBLSPageSize, rec[@"cursorEntry"], YES);
    if (!page) {
        [self fail:nil];
        return;
    }
    [self deliver:page headers:rec[@"headers"]];
}

@end

// MARK: - Installing the protocol (the same way Tenor.x does)

static NSArray<Class>* NFBLSProtocolClasses(NSArray<Class>* existing) {
    if ([existing containsObject:[NFBListSortURLProtocol class]]) return existing;
    NSMutableArray<Class>* classes = existing ? [existing mutableCopy] : [NSMutableArray array];
    [classes insertObject:[NFBListSortURLProtocol class] atIndex:0];
    return classes;
}

static void NFBLSInstall(NSURLSessionConfiguration* configuration) {
    if (configuration) configuration.protocolClasses = NFBLSProtocolClasses(configuration.protocolClasses);
}

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration*)defaultSessionConfiguration {
    NSURLSessionConfiguration* configuration = %orig;
    NFBLSInstall(configuration);
    return configuration;
}

+ (NSURLSessionConfiguration*)ephemeralSessionConfiguration {
    NSURLSessionConfiguration* configuration = %orig;
    NFBLSInstall(configuration);
    return configuration;
}

%end

%hook NSURLSession

+ (NSURLSession*)sessionWithConfiguration:(NSURLSessionConfiguration*)configuration {
    NFBLSInstall(configuration);
    return %orig;
}

+ (NSURLSession*)sessionWithConfiguration:(NSURLSessionConfiguration*)configuration
                                 delegate:(id)delegate
                            delegateQueue:(NSOperationQueue*)queue {
    if (queue.underlyingQueue == NFBLSQueue()) return %orig; // our own private session
    NFBLSInstall(configuration);
    return %orig;
}

%end

// MARK: - The button on lists

static UIWindow* NFBLSKeyWindow(void) {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* w in ((UIWindowScene*)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

// The view controller the user is looking at: through presented screens, navigation stacks,
// tabs, and custom containers (the largest visible child).
static UIViewController* NFBLSVisibleLeaf(void) {
    UIViewController* vc = NFBLSKeyWindow().rootViewController;
    for (int guard = 0; vc && guard < 40; guard++) {
        UIViewController* presented = vc.presentedViewController;
        if (presented && !presented.isBeingDismissed && ![presented isKindOfClass:[UIAlertController class]]) {
            vc = presented;
            continue;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController* top = ((UINavigationController*)vc).topViewController;
            if (top && top != vc) {
                vc = top;
                continue;
            }
            break;
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController* sel = ((UITabBarController*)vc).selectedViewController;
            if (sel && sel != vc) {
                vc = sel;
                continue;
            }
            break;
        }
        UIViewController* best = nil;
        CGFloat bestArea = 0;
        for (UIViewController* child in vc.childViewControllers) {
            if (!child.isViewLoaded || !child.view.window || child.view.hidden || child.view.alpha < 0.05) continue;
            CGRect r = [child.view convertRect:child.view.bounds toView:nil];
            CGRect onScreen = CGRectIntersection(r, child.view.window.bounds);
            CGFloat area = CGRectIsNull(onScreen) ? 0 : onScreen.size.width * onScreen.size.height;
            if (area > bestArea) {
                bestArea = area;
                best = child;
            }
        }
        if (!best) break;
        vc = best;
    }
    return vc;
}

// A view that does not scroll, so the button stays put.
static UIViewController* NFBLSHostFor(UIViewController* leaf) {
    UIViewController* vc = leaf;
    while (vc && [vc.view isKindOfClass:[UIScrollView class]] && vc.parentViewController)
        vc = vc.parentViewController;
    return vc;
}

static NSString* NFBLSChain(UIViewController* vc) {
    NSMutableArray* names = [NSMutableArray array];
    for (UIViewController* v = vc; v && names.count < 6; v = v.parentViewController)
        [names addObject:NSStringFromClass([v class])];
    return [names componentsJoinedByString:@" < "];
}

static __weak UIButton* gButton;
static NSString* gButtonListId;
static NSString* gButtonProgress;

static void NFBLSToast(NSString* text) {
    UIWindow* w = NFBLSKeyWindow();
    if (!w || !text.length) return;
    UIView* box = [[UIView alloc] init];
    box.backgroundColor = [UIColor colorWithRed:0.11 green:0.61 blue:0.94 alpha:0.96];
    box.layer.cornerRadius = 12;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.alpha = 0;
    box.userInteractionEnabled = NO;
    UILabel* label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:label];
    [w addSubview:box];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor
                                            constant:14],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor
                                             constant:-14],
        [label.topAnchor constraintEqualToAnchor:box.topAnchor
                                        constant:10],
        [label.bottomAnchor constraintEqualToAnchor:box.bottomAnchor
                                           constant:-10],
        [box.centerXAnchor constraintEqualToAnchor:w.centerXAnchor],
        [box.widthAnchor constraintLessThanOrEqualToAnchor:w.widthAnchor
                                                  constant:-40],
        [box.topAnchor constraintEqualToAnchor:w.safeAreaLayoutGuide.topAnchor
                                      constant:56],
    ]];
    [UIView animateWithDuration:0.2 animations:^{ box.alpha = 1; }];
    NSTimeInterval shown = MIN(8.0, 2.5 + text.length / 30.0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(shown * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ box.alpha = 0; } completion:^(BOOL done) { [box removeFromSuperview]; }];
    });
}

static void NFBLSShowAlert(NSString* title, NSString* message) {
    UIViewController* top = topMostController();
    if (!top) return;
    UIAlertController* a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

// Ask X to load the list again, if its pull-to-refresh is a standard one. Returns whether it could.
static BOOL NFBLSTriggerRefresh(UIView* root) {
    __block UIRefreshControl* found = nil;
    EnumerateSubviewsRecursively(root, ^(UIView* v) {
        if (!found && [v isKindOfClass:[UIScrollView class]] && ((UIScrollView*)v).refreshControl) found = ((UIScrollView*)v).refreshControl;
    });
    if (!found) return NO;
    UIScrollView* sv = (UIScrollView*)found.superview;
    if ([sv isKindOfClass:[UIScrollView class]]) [sv setContentOffset:CGPointMake(0, -sv.adjustedContentInset.top - found.bounds.size.height) animated:YES];
    [found beginRefreshing];
    [found sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

static void NFBLSApply(NSString* why) {
    UIView* host = gButton.superview;
    BOOL refreshed = host && NFBLSTriggerRefresh(host);
    NSString* how = refreshed ? @"Reloading the list…" : @"Pull down to refresh, or go back and open the list again, to apply.";
    NFBLSToast(why.length ? [NSString stringWithFormat:@"%@ %@", why, how] : how);
    dispatch_async(NFBLSQueue(), ^{
        NFBLSEvent([NSString stringWithFormat:@"applied from the list button (%@)", refreshed ? @"refresh control found" : @"no standard refresh control"]);
    });
}

static void NFBLSSetInteger(NSString* key, NSInteger value) {
    [[NSUserDefaults standardUserDefaults] setInteger:value forKey:key];
    NFBListSortSettingsChanged();
}

static void NFBLSSetBool(NSString* key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    NFBListSortSettingsChanged();
}

static UIMenu* NFBLSChoiceMenu(NSString* title, NSString* key, NSArray<NSArray*>* choices) {
    NSInteger current = [BHTSettings integerForKey:key];
    NSMutableArray* actions = [NSMutableArray array];
    for (NSArray* c in choices) {
        NSInteger value = [c[0] integerValue];
        UIAction* a = [UIAction actionWithTitle:c[1]
                                          image:nil
                                     identifier:nil
                                        handler:^(UIAction* action) {
                                            NFBLSSetInteger(key, value);
                                            if (NFBLSPopular()) NFBLSApply(nil);
                                        }];
        a.state = value == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    return [UIMenu menuWithTitle:[NSString stringWithFormat:@"%@: %@", title, NFBListSortLabelFor(choices, current)]
                           image:nil
                      identifier:nil
                         options:0
                        children:actions];
}

static UIMenu* NFBLSMenu(void) {
    BOOL popular = NFBLSPopular();
    UIAction* latest = [UIAction actionWithTitle:@"Latest"
                                           image:[UIImage systemImageNamed:@"clock"]
                                      identifier:nil
                                         handler:^(UIAction* a) {
                                             if (!NFBLSPopular()) return;
                                             NFBLSSetBool(NFBLSKeyPopular, NO);
                                             NFBLSApply(@"Lists are back to newest first.");
                                         }];
    latest.state = popular ? UIMenuElementStateOff : UIMenuElementStateOn;
    UIAction* pop = [UIAction actionWithTitle:@"Popular"
                                        image:[UIImage systemImageNamed:@"flame"]
                                   identifier:nil
                                      handler:^(UIAction* a) {
                                          if (NFBLSPopular()) return;
                                          NFBLSSetBool(NFBLSKeyPopular, YES);
                                          NFBLSApply(@"Lists will open sorted by popularity. The first time, the list is scanned, which can take a little while.");
                                      }];
    pop.state = popular ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIMenu* order = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[latest, pop]];

    UIAction* reposts = [UIAction actionWithTitle:@"Reposts"
                                            image:nil
                                       identifier:nil
                                          handler:^(UIAction* a) {
                                              NFBLSSetBool(NFBLSKeyReposts, ![BHTSettings boolForKey:NFBLSKeyReposts]);
                                              if (NFBLSPopular()) NFBLSApply(nil);
                                          }];
    reposts.state = [BHTSettings boolForKey:NFBLSKeyReposts] ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction* onePer = [UIAction actionWithTitle:@"One per account"
                                           image:nil
                                      identifier:nil
                                         handler:^(UIAction* a) {
                                             NFBLSSetBool(NFBLSKeyOnePerAccount, ![BHTSettings boolForKey:NFBLSKeyOnePerAccount]);
                                             if (NFBLSPopular()) NFBLSApply(nil);
                                         }];
    onePer.state = [BHTSettings boolForKey:NFBLSKeyOnePerAccount] ? UIMenuElementStateOn : UIMenuElementStateOff;

    NSString* listId = gButtonListId;
    UIAction* rescan = [UIAction actionWithTitle:@"Rescan this list"
                                           image:[UIImage systemImageNamed:@"arrow.clockwise"]
                                      identifier:nil
                                         handler:^(UIAction* a) {
                                             dispatch_async(NFBLSQueue(), ^{
                                                 if (listId) [gForced addObject:listId];
                                                 NFBLSEvent([NSString stringWithFormat:@"rescan asked for list %@", NFBLSShortID(listId)]);
                                             });
                                             if (!NFBLSPopular()) NFBLSSetBool(NFBLSKeyPopular, YES);
                                             NFBLSApply(@"The list will be scanned again for fresh counts.");
                                         }];
    UIAction* about = [UIAction actionWithTitle:@"About this ranking"
                                          image:[UIImage systemImageNamed:@"info.circle"]
                                     identifier:nil
                                        handler:^(UIAction* a) {
                                            dispatch_async(NFBLSQueue(), ^{
                                                NSMutableDictionary* rec = NFBLSScanFor(listId);
                                                NSString* text = rec ? [NFBLSSummaryLines(rec) componentsJoinedByString:@"\n"] : @"This list has not been scanned yet. Choose Popular to scan it.";
                                                dispatch_async(dispatch_get_main_queue(), ^{ NFBLSShowAlert(@"List sorting", text); });
                                            });
                                        }];
    UIMenu* options = [UIMenu menuWithTitle:@""
                                      image:nil
                                 identifier:nil
                                    options:UIMenuOptionsDisplayInline
                                   children:@[
                                       NFBLSChoiceMenu(@"Rank by", NFBLSKeyMetric, NFBListSortMetricChoices()),
                                       NFBLSChoiceMenu(@"Within", NFBLSKeyTimeWindow, NFBListSortWindowChoices()),
                                       NFBLSChoiceMenu(@"Show", NFBLSKeyShow, NFBListSortShowChoices()),
                                       reposts,
                                       onePer,
                                   ]];
    NSMutableArray* toolItems = [NSMutableArray arrayWithObjects:rescan, about, nil];
    if (gButtonProgress) {
        UIAction* stop = [UIAction actionWithTitle:@"Stop scanning"
                                             image:[UIImage systemImageNamed:@"stop.circle"]
                                        identifier:nil
                                           handler:^(UIAction* a) {
                                               dispatch_async(NFBLSQueue(), ^{
                                                   if (listId) [gStopping addObject:listId];
                                                   NFBLSEvent([NSString stringWithFormat:@"stop asked for list %@", NFBLSShortID(listId)]);
                                               });
                                               NFBLSToast(@"Stopping after this page. What has loaded so far will be sorted.");
                                           }];
        stop.attributes = UIMenuElementAttributesDestructive;
        [toolItems insertObject:stop atIndex:0];
    }
    UIMenu* tools = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:toolItems];
    return [UIMenu menuWithTitle:@"List order" image:nil identifier:nil options:0 children:@[order, options, tools]];
}

static void NFBLSRefreshButton(void) {
    UIButton* b = gButton;
    if (!b) return;
    UIButtonConfiguration* c = b.configuration;
    NSString* title = NFBLSPopular() ? (gButtonProgress ?: @"Popular") : @"Latest";
    c.title = title;
    b.configuration = c;
    b.menu = NFBLSMenu();
}

static void NFBLSInstallButton(NSString* listId) {
    if (![BHTSettings boolForKey:NFBLSKeyButton]) {
        [gButton removeFromSuperview];
        return;
    }
    UIViewController* host = NFBLSHostFor(NFBLSVisibleLeaf());
    UIView* view = host.view;
    if (!view || !view.window) return;
    gButtonListId = listId;
    dispatch_async(NFBLSQueue(), ^{ gButtonHost = NFBLSChain(host); });
    UIButton* b = gButton;
    if (b && b.superview == view) {
        NFBLSRefreshButton();
        return;
    }
    [b removeFromSuperview];
    UIButtonConfiguration* c = [UIButtonConfiguration grayButtonConfiguration];
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.buttonSize = UIButtonConfigurationSizeSmall;
    c.image = [UIImage systemImageNamed:@"arrow.up.arrow.down"];
    c.imagePadding = 5;
    c.baseForegroundColor = [UIColor colorWithRed:0.11 green:0.61 blue:0.94 alpha:1];
    c.background.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.92];
    c.background.strokeColor = [UIColor.separatorColor colorWithAlphaComponent:0.6];
    c.background.strokeWidth = 1;
    b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    b.showsMenuAsPrimaryAction = YES;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.accessibilityLabel = @"List order";
    [view addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.leadingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.leadingAnchor
                                        constant:16],
        [b.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor
                                       constant:-16],
    ]];
    gButton = b;
    NFBLSRefreshButton();
}

// A list's posts were asked for: put the button on the screen showing it. Tried twice, because
// the request often goes out while the list screen is still sliding in.
static void NFBLSNoteListSeen(NSString* listId) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSTimeInterval last;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - last < 0.3) return;
        last = now;
        for (NSNumber* delay in @[@0.6, @1.6]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NFBLSInstallButton(listId);
            });
        }
    });
}

void NFBListSortSettingsChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![BHTSettings boolForKey:NFBLSKeyButton]) [gButton removeFromSuperview];
        NFBLSRefreshButton();
        [[NSNotificationCenter defaultCenter] postNotificationName:NFBLSSettingsNote object:nil];
    });
}

%ctor {
    NFBLSSetUpState();
    [NSURLProtocol registerClass:[NFBListSortURLProtocol class]];
    %init;

    [[NSNotificationCenter defaultCenter] addObserverForName:NFBLSProgressNote
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* n) {
                                                      if (![n.userInfo[@"listId"] isEqual:gButtonListId]) return;
                                                      gButtonProgress = [NSString stringWithFormat:@"Scanning… %@", n.userInfo[@"count"]];
                                                      NFBLSRefreshButton();
                                                  }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NFBLSDoneNote
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* n) {
                                                      gButtonProgress = nil;
                                                      NFBLSRefreshButton();
                                                      NSArray* lines = n.userInfo[@"lines"];
                                                      if (lines.count >= 2) NFBLSToast([NSString stringWithFormat:@"%@ %@", lines[0], lines[1]]);
                                                  }];
}
