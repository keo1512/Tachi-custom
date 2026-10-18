#import "TachiSourceBrowser.h"
#import <WebKit/WebKit.h>
#import <math.h>

static void TachiBrowserOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

@interface TachiSourceBrowser () <WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate, WKHTTPCookieStoreObserver>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSURL *origin;
@property(nonatomic, copy) FlutterResult completion;
@property(nonatomic) BOOL completing;
@property(nonatomic) BOOL completed;
@property(nonatomic, strong) UIBarButtonItem *backButton;
@property(nonatomic, strong) UIBarButtonItem *forwardButton;
@property(nonatomic, strong) UIBarButtonItem *optionsButton;
@property(nonatomic, strong) UILabel *pageErrorLabel;
@property(nonatomic, strong) NSDictionary *seed;
@property(nonatomic) BOOL automatic;
@property(nonatomic) BOOL verified;
@property(nonatomic) BOOL cleared;
@property(nonatomic) BOOL pageReady;
@property(nonatomic) BOOL mainResponseAllowed;
@property(nonatomic) BOOL observingCookies;
@property(nonatomic) BOOL checkingClearance;
+ (BOOL)isHTTPURL:(NSURL *)url;
- (void)complete:(id)value dismiss:(BOOL)dismiss;
- (NSArray *)sourceCookies:(NSArray<NSHTTPCookie *> *)cookies;
@end

// Keep one session alive through presentation, cookie collection and dismissal.
// Access is confined to the main queue, including calls from non-UI clients.
static TachiSourceBrowser *tachiActiveBrowser;

@implementation TachiSourceBrowser
+ (void)openURL:(NSString *)url result:(FlutterResult)result {
  [self openOptions:@{@"url":url ?: @""} result:result];
}
+ (void)openOptions:(NSDictionary *)options result:(FlutterResult)result {
  TachiBrowserOnMain(^{
    id url = options[@"url"];
    NSURL *origin = [url isKindOfClass:NSString.class] ? [NSURL URLWithString:url] : nil;
    if (![self isHTTPURL:origin]) {
      result([FlutterError errorWithCode:@"INVALID_SOURCE_URL" message:@"Địa chỉ nguồn không hợp lệ." details:nil]);
      return;
    }
    if (tachiActiveBrowser) {
      result([FlutterError errorWithCode:@"BROWSER_ALREADY_OPEN" message:@"Hãy đóng trang nguồn đang mở trước." details:nil]);
      return;
    }
    UIViewController *presenter = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
      for (UIWindow *window in ((UIWindowScene *)scene).windows) {
        if (window.isKeyWindow) { presenter = window.rootViewController; break; }
      }
      if (presenter) break;
    }
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    // Also reject an already-presented browser if a caller constructed it
    // outside openURL, instead of stacking another browser over that sheet.
    BOOL browserPresented = [presenter isKindOfClass:TachiSourceBrowser.class] ||
      ([presenter isKindOfClass:UINavigationController.class] &&
       [((UINavigationController *)presenter).topViewController isKindOfClass:TachiSourceBrowser.class]);
    if (browserPresented) {
      result([FlutterError errorWithCode:@"BROWSER_ALREADY_OPEN" message:@"Hãy đóng trang nguồn đang mở trước." details:nil]);
      return;
    }
    if (!presenter || !presenter.viewIfLoaded.window || presenter.isBeingPresented || presenter.isBeingDismissed ||
        [presenter isKindOfClass:UIAlertController.class]) {
      result([FlutterError errorWithCode:@"BROWSER_UNAVAILABLE" message:@"Không mở được trang nguồn." details:nil]);
      return;
    }
    TachiSourceBrowser *browser = [TachiSourceBrowser new];
    browser.origin = origin;
    browser.automatic = [options[@"automatic"] isEqual:@YES];
    id seed = options[@"seed"];
    if (seed && seed != NSNull.null && (![seed isKindOfClass:NSDictionary.class] ||
        ![seed[@"url"] isEqual:origin.absoluteString] || ![seed[@"cookies"] isKindOfClass:NSArray.class] ||
        [seed[@"cookies"] count] > 512)) {
      result([FlutterError errorWithCode:@"INVALID_BROWSER_SESSION" message:@"Phiên nguồn không hợp lệ." details:nil]);
      return;
    }
    browser.seed = [seed isKindOfClass:NSDictionary.class] ? seed : nil;
    browser.completion = result;
    tachiActiveBrowser = browser;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:browser];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.presentationController.delegate = browser;
    [presenter presentViewController:navigation animated:YES completion:^{
      navigation.presentationController.delegate = browser;
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!navigation.presentingViewController && !browser.completed) {
        [browser complete:[FlutterError errorWithCode:@"BROWSER_UNAVAILABLE" message:@"Không mở được trang nguồn." details:nil] dismiss:NO];
      }
    });
    if (browser.automatic) {
      __weak TachiSourceBrowser *weakBrowser = browser;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        TachiSourceBrowser *current = weakBrowser;
        if (current && !current.completed && !current.completing)
          [current complete:[FlutterError errorWithCode:@"BROWSER_VERIFICATION_TIMEOUT" message:@"Xác minh quá lâu. Hãy mở trang nguồn và thử lại." details:nil] dismiss:YES];
      });
    }
  });
}
+ (BOOL)isHTTPURL:(NSURL *)url {
  return url.host.length && [@[@"https", @"http"] containsObject:url.scheme.lowercaseString] &&
    !url.user.length && !url.password.length;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.origin.host;
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Xong" style:UIBarButtonItemStyleDone target:self action:@selector(finish)];
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
  self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
  NSDictionary *agents = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"dev.tachibooks.browserUserAgents"];
  NSString *agent = agents[self.origin.host.lowercaseString];
  if ([agent isKindOfClass:NSString.class] && [self validUserAgent:agent]) self.webView.customUserAgent = agent;
  NSString *seedAgent = self.seed[@"userAgent"];
  if ([seedAgent isKindOfClass:NSString.class] && seedAgent.length && [self validUserAgent:seedAgent]) self.webView.customUserAgent = seedAgent;
  self.webView.navigationDelegate = self;
  self.webView.UIDelegate = self;
  self.webView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.webView];
  [NSLayoutConstraint activateConstraints:@[
    [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
  ]];
  self.pageErrorLabel = [UILabel new];
  self.pageErrorLabel.translatesAutoresizingMaskIntoConstraints = NO;
  self.pageErrorLabel.numberOfLines = 0;
  self.pageErrorLabel.textAlignment = NSTextAlignmentCenter;
  self.pageErrorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  self.pageErrorLabel.textColor = UIColor.labelColor;
  self.pageErrorLabel.backgroundColor = UIColor.secondarySystemBackgroundColor;
  self.pageErrorLabel.hidden = YES;
  [self.view addSubview:self.pageErrorLabel];
  [NSLayoutConstraint activateConstraints:@[
    [self.pageErrorLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    [self.pageErrorLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
    [self.pageErrorLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12]
  ]];
  self.backButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.backward"] style:UIBarButtonItemStylePlain target:self action:@selector(goBack)];
  self.forwardButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"] style:UIBarButtonItemStylePlain target:self action:@selector(goForward)];
  self.optionsButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showOptions)];
  self.backButton.accessibilityLabel = @"Trang trước";
  self.forwardButton.accessibilityLabel = @"Trang tiếp theo";
  self.optionsButton.accessibilityLabel = @"Tùy chọn trang nguồn";
  self.toolbarItems = @[self.backButton, self.forwardButton,
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], self.optionsButton];
  [self.navigationController setToolbarHidden:NO animated:NO];
  [self updateNavigationButtons];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationBackgrounded:) name:UIApplicationDidEnterBackgroundNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionInvalidated:) name:@"dev.tachibooks.clearSourceSessions" object:nil];
  [self seedAndLoad];
}
- (void)applicationBackgrounded:(NSNotification *)notification {
  if (self.automatic && !self.completed) [self complete:@{@"cancelled":@YES} dismiss:YES];
}
- (void)sessionInvalidated:(NSNotification *)notification {
  if (!self.completed) [self complete:@{@"cancelled":@YES} dismiss:YES];
}
- (BOOL)cookieDomainMatches:(NSString *)domain hostOnly:(BOOL)hostOnly {
  if (![domain isKindOfClass:NSString.class]) return NO;
  NSString *host = self.origin.host.lowercaseString;
  domain = domain.lowercaseString;
  if ([domain hasPrefix:@"."]) domain = [domain substringFromIndex:1];
  return domain.length && ![domain hasPrefix:@"."] && ([host isEqual:domain] || (!hostOnly && [host hasSuffix:[@"." stringByAppendingString:domain]]));
}
- (void)seedAndLoad {
  WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
  void (^load)(void) = ^{
    if (self.completed || self.completing) return;
    [store addObserver:self]; self.observingCookies = YES;
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.origin]];
  };
  if (!self.seed) { load(); return; }
  NSMutableArray<NSHTTPCookie *> *incoming = [NSMutableArray new];
  for (id item in self.seed[@"cookies"]) {
    if (![item isKindOfClass:NSDictionary.class] || ![item[@"name"] isKindOfClass:NSString.class] ||
        ![item[@"value"] isKindOfClass:NSString.class] || ![item[@"path"] isKindOfClass:NSString.class] ||
        ![item[@"hostOnly"] isKindOfClass:NSNumber.class] || ![item[@"secure"] isKindOfClass:NSNumber.class] || ![item[@"httpOnly"] isKindOfClass:NSNumber.class] ||
        ![item[@"name"] length] || [item[@"name"] length] + [item[@"value"] length] > 4096 || ![item[@"path"] hasPrefix:@"/"] ||
        ![self cookieDomainMatches:item[@"domain"] hostOnly:[item[@"hostOnly"] boolValue]]) {
      [self complete:[FlutterError errorWithCode:@"INVALID_BROWSER_SESSION" message:@"Cookie nguồn không hợp lệ." details:nil] dismiss:YES]; return;
    }
    NSString *domain = [item[@"domain"] hasPrefix:@"."] ? [item[@"domain"] substringFromIndex:1] : item[@"domain"];
    NSMutableDictionary *properties = [@{NSHTTPCookieName:item[@"name"], NSHTTPCookieValue:item[@"value"],
      NSHTTPCookieDomain:[item[@"hostOnly"] boolValue] ? domain : [@"." stringByAppendingString:domain],
      NSHTTPCookiePath:item[@"path"], NSHTTPCookieOriginURL:self.origin} mutableCopy];
    if ([item[@"secure"] boolValue]) properties[NSHTTPCookieSecure] = @"TRUE";
    if ([item[@"httpOnly"] boolValue]) properties[@"HttpOnly"] = @"TRUE";
    id expiry = item[@"expiresAt"];
    if (expiry && expiry != NSNull.null) {
      if (![expiry isKindOfClass:NSNumber.class] || !isfinite([expiry doubleValue])) {
        [self complete:[FlutterError errorWithCode:@"INVALID_BROWSER_SESSION" message:@"Hạn cookie không hợp lệ." details:nil] dismiss:YES]; return;
      }
      NSDate *expires = [NSDate dateWithTimeIntervalSince1970:[expiry doubleValue] / 1000];
      if (expires.timeIntervalSinceNow <= 0) continue;
      properties[NSHTTPCookieExpires] = expires;
    }
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
    if (!cookie) { [self complete:[FlutterError errorWithCode:@"INVALID_BROWSER_SESSION" message:@"Không nạp được cookie nguồn." details:nil] dismiss:YES]; return; }
    [incoming addObject:cookie];
  }
  [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
    TachiBrowserOnMain(^{
      if (self.completed || self.completing) return;
      dispatch_group_t removals = dispatch_group_create();
      for (NSHTTPCookie *cookie in cookies) if ([self cookieDomainMatches:cookie.domain hostOnly:![cookie.domain hasPrefix:@"."]]) {
        dispatch_group_enter(removals); [store deleteCookie:cookie completionHandler:^{ dispatch_group_leave(removals); }];
      }
      dispatch_group_notify(removals, dispatch_get_main_queue(), ^{
        if (self.completed || self.completing) return;
        dispatch_group_t writes = dispatch_group_create();
        for (NSHTTPCookie *cookie in incoming) {
          dispatch_group_enter(writes); [store setCookie:cookie completionHandler:^{ dispatch_group_leave(writes); }];
        }
        dispatch_group_notify(writes, dispatch_get_main_queue(), load);
      });
    });
  }];
}
- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore { TachiBrowserOnMain(^{ [self checkClearance]; }); }
- (void)checkClearance {
  if (!self.automatic || self.checkingClearance || !self.pageReady || !self.mainResponseAllowed || self.completed || self.completing) return;
  self.checkingClearance = YES;
  [self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
    TachiBrowserOnMain(^{
      self.checkingClearance = NO;
      if (!self.pageReady || !self.mainResponseAllowed || self.completed || self.completing) return;
      for (NSDictionary *cookie in [self sourceCookies:cookies]) if ([cookie[@"name"] isEqual:@"cf_clearance"] && [cookie[@"value"] length]) {
        self.verified = YES; [self finish]; break;
      }
    });
  }];
}
- (void)reload { if (!self.completing && !self.completed) [self.webView reload]; }
- (void)goBack { if (!self.completing && !self.completed && self.webView.canGoBack) [self.webView goBack]; }
- (void)goForward { if (!self.completing && !self.completed && self.webView.canGoForward) [self.webView goForward]; }
- (void)updateNavigationButtons {
  self.backButton.enabled = !self.completing && !self.completed && self.webView.canGoBack;
  self.forwardButton.enabled = !self.completing && !self.completed && self.webView.canGoForward;
  self.optionsButton.enabled = !self.completing && !self.completed;
}
- (BOOL)validUserAgent:(NSString *)agent {
  return agent.length <= 1024 && ![agent containsString:@"\r"] && ![agent containsString:@"\n"];
}
- (void)setBrowserUserAgent:(NSString *)agent {
  if (self.completing || self.completed || ![agent isKindOfClass:NSString.class] || ![self validUserAgent:agent]) return;
  NSMutableDictionary *agents = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"dev.tachibooks.browserUserAgents"] mutableCopy] ?: [NSMutableDictionary new];
  NSString *key = self.origin.host.lowercaseString;
  if (agent.length) agents[key] = agent;
  else [agents removeObjectForKey:key];
  [NSUserDefaults.standardUserDefaults setObject:agents forKey:@"dev.tachibooks.browserUserAgents"];
  self.webView.customUserAgent = agent.length ? agent : nil;
  [self reload];
}
- (void)editUserAgent {
  UIAlertController *dialog = [UIAlertController alertControllerWithTitle:@"User-Agent của nguồn" message:@"Để trống để dùng mặc định của iOS. Phiên nguồn được lưu khi bấm Xong." preferredStyle:UIAlertControllerStyleAlert];
  [dialog addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.text = self.webView.customUserAgent ?: @"";
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  }];
  [dialog addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
  __weak TachiSourceBrowser *weakBrowser = self;
  [dialog addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    TachiSourceBrowser *browser = weakBrowser;
    NSString *agent = dialog.textFields.firstObject.text ?: @"";
    if (!browser || browser.completed || browser.completing) return;
    if (![browser validUserAgent:agent]) {
      [browser showPageError:@"User-Agent tối đa 1.024 ký tự và không được chứa dấu xuống dòng."];
      return;
    }
    [browser setBrowserUserAgent:agent];
  }]];
  [self presentViewController:dialog animated:YES completion:nil];
}
- (void)clearSourceCookies {
  if (self.completing || self.completed) return;
  self.optionsButton.enabled = NO;
  WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
  __weak TachiSourceBrowser *weakBrowser = self;
  [self.webView stopLoading];
  [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
    TachiBrowserOnMain(^{
      TachiSourceBrowser *browser = weakBrowser;
      if (!browser || browser.completed || browser.completing) return;
      NSSet *scopedNames = [NSSet setWithArray:[[browser sourceCookies:cookies] valueForKey:@"name"]];
      NSString *host = browser.origin.host.lowercaseString;
      dispatch_group_t group = dispatch_group_create();
      for (NSHTTPCookie *cookie in cookies) {
        NSString *domain = cookie.domain.lowercaseString;
        BOOL hostOnly = ![domain hasPrefix:@"."];
        if (!hostOnly) domain = [domain substringFromIndex:1];
        BOOL matches = [host isEqualToString:domain] || (!hostOnly && [host hasSuffix:[@"." stringByAppendingString:domain]]);
        if (!matches || ![scopedNames containsObject:cookie.name]) continue;
        dispatch_group_enter(group);
        [store deleteCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
      }
      dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        TachiSourceBrowser *current = weakBrowser;
        if (!current || current.completed || current.completing) return;
        current.cleared = YES;
        current.verified = NO;
        [current finish];
      });
    });
  }];
}
- (void)showOptions {
  if (self.completing || self.completed || self.presentedViewController) return;
  UIAlertController *menu = [UIAlertController alertControllerWithTitle:self.origin.host message:nil preferredStyle:UIAlertControllerStyleActionSheet];
  __weak TachiSourceBrowser *weakBrowser = self;
  [menu addAction:[UIAlertAction actionWithTitle:@"Mở trong trình duyệt ngoài" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    TachiSourceBrowser *browser = weakBrowser;
    NSURL *url = browser.webView.URL ?: browser.origin;
    if (browser && !browser.completed && [TachiSourceBrowser isHTTPURL:url])
      [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
  }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Chỉnh User-Agent" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakBrowser editUserAgent]; }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Khôi phục User-Agent mặc định" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakBrowser setBrowserUserAgent:@""]; }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Ẩn thông báo Cloudflare của domain này 24 giờ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    TachiSourceBrowser *browser = weakBrowser;
    if (!browser || browser.completed || browser.completing) return;
    NSMutableDictionary *domains = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"dev.tachibooks.browserMutedDomains"] mutableCopy] ?: [NSMutableDictionary new];
    if (domains.count >= 256) [domains removeAllObjects];
    domains[browser.origin.host.lowercaseString] = @([NSDate date].timeIntervalSince1970 + 86400);
    [NSUserDefaults.standardUserDefaults setObject:domains forKey:@"dev.tachibooks.browserMutedDomains"];
    browser.pageErrorLabel.hidden = YES;
  }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Đặt lại domain đã ẩn Cloudflare" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"dev.tachibooks.browserMutedDomains"];
  }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Xóa cookie nguồn và đóng" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [weakBrowser clearSourceCookies]; }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
  menu.popoverPresentationController.barButtonItem = self.optionsButton;
  [self presentViewController:menu animated:YES completion:nil];
}
- (void)showPageError:(NSString *)message {
  if (self.completing || self.completed) return;
  self.pageErrorLabel.text = [NSString stringWithFormat:@"%@\nBấm tải lại để thử lại.", message];
  self.pageErrorLabel.hidden = NO;
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation { self.pageErrorLabel.hidden = YES; self.pageReady = NO; self.mainResponseAllowed = NO; }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { [self updateNavigationButtons]; self.pageReady = YES; [self checkClearance]; }
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
  if (response.isForMainFrame && [response.response isKindOfClass:NSHTTPURLResponse.class]) {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response.response;
    self.mainResponseAllowed = http.statusCode >= 200 && http.statusCode < 300 &&
      [http.URL.host.lowercaseString isEqual:self.origin.host.lowercaseString] &&
      ![http.URL.path hasPrefix:@"/cdn-cgi/"];
    for (id key in http.allHeaderFields) if ([[[key description] lowercaseString] isEqual:@"cf-mitigated"] &&
        [[[http.allHeaderFields[key] description] lowercaseString] isEqual:@"challenge"]) self.mainResponseAllowed = NO;
    if (http.statusCode >= 400) {
      BOOL cloudflare = NO;
      for (id key in http.allHeaderFields) {
        NSString *name = [[key description] lowercaseString];
        NSString *value = [[http.allHeaderFields[key] description] lowercaseString];
        if ([name isEqualToString:@"cf-ray"] || ([name isEqualToString:@"server"] && [value containsString:@"cloudflare"])) cloudflare = YES;
      }
      NSDictionary *domains = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"dev.tachibooks.browserMutedDomains"];
      NSNumber *until = domains[self.origin.host.lowercaseString];
      BOOL muted = [until isKindOfClass:NSNumber.class] && until.doubleValue > [NSDate date].timeIntervalSince1970;
      if (!(cloudflare && muted)) [self showPageError:[NSString stringWithFormat:@"Trang nguồn trả lỗi HTTP %ld.%@", (long)http.statusCode, cloudflare ? @" Hoàn tất xác minh trên trang nếu được hỗ trợ rồi bấm Xong." : @""]];
    }
  }
  decisionHandler(WKNavigationResponsePolicyAllow);
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  [self updateNavigationButtons];
  if (error.code != NSURLErrorCancelled) [self showPageError:error.code == NSURLErrorTimedOut ? @"Nguồn phản hồi quá lâu. Hãy thử lại." : @"Không kết nối được với trang nguồn. Hãy kiểm tra mạng rồi thử lại."];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self webView:webView didFailNavigation:navigation withError:error]; }
- (BOOL)allowsNavigationURL:(NSURL *)url mainFrame:(BOOL)mainFrame {
  if (self.completing || self.completed) return NO;
  if ([url.absoluteString isEqualToString:@"about:blank"] || [url.absoluteString isEqualToString:@"about:srcdoc"]) return !mainFrame;
  if (![TachiSourceBrowser isHTTPURL:url]) return NO;
  // Third-party captcha frames remain possible, but the visible page and any
  // new-window link stay on the selected source host.
  return !mainFrame || [url.host.lowercaseString isEqualToString:self.origin.host.lowercaseString];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  BOOL mainFrame = !action.targetFrame || action.targetFrame.isMainFrame;
  decisionHandler([self allowsNavigationURL:action.request.URL mainFrame:mainFrame] ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
  if (!action.targetFrame && [self allowsNavigationURL:action.request.URL mainFrame:YES]) {
    // Handle target=_blank without creating an untracked sheet/session.
    [webView loadRequest:action.request];
  }
  return nil;
}
- (void)finish {
  TachiBrowserOnMain(^{
    if (self.completing || self.completed) return;
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
      [self complete:@{@"cancelled":@YES} dismiss:NO];
      return;
    }
    self.completing = YES;
    [self updateNavigationButtons];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    self.webView.userInteractionEnabled = NO;
    self.navigationController.modalInPresentation = YES;
    [self.webView stopLoading];
    __weak TachiSourceBrowser *weakBrowser = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      TachiSourceBrowser *browser = weakBrowser;
      if (browser && browser.completing && !browser.completed) {
        [browser complete:[FlutterError errorWithCode:@"BROWSER_SESSION_FAILED" message:@"Không đọc được phiên trang nguồn. Hãy mở lại và thử lần nữa." details:nil] dismiss:YES];
      }
    });
    [self.webView evaluateJavaScript:@"navigator.userAgent" completionHandler:^(id value, NSError *error) {
      TachiBrowserOnMain(^{
        TachiSourceBrowser *browser = weakBrowser;
        if (!browser || browser.completed) return;
        NSString *agent = [value isKindOfClass:NSString.class] ? value : nil;
        if (error || !agent.length || agent.length > 1024 || [agent containsString:@"\r"] || [agent containsString:@"\n"]) {
          [browser complete:[FlutterError errorWithCode:@"BROWSER_SESSION_FAILED" message:@"Không đọc được phiên trang nguồn. Hãy mở lại và thử lần nữa." details:nil] dismiss:YES];
          return;
        }
        [browser.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
          TachiBrowserOnMain(^{
            TachiSourceBrowser *current = weakBrowser;
            if (!current || current.completed) return;
            // Explicit logout must publish an empty source session even when a
            // cancelled page response races the WebKit cookie collection.
            NSArray *session = current.cleared ? @[] : [current sourceCookies:cookies];
            if (session.count > 512) {
              [current complete:[FlutterError errorWithCode:@"BROWSER_SESSION_FAILED" message:@"Phiên trang nguồn vượt giới hạn cookie." details:nil] dismiss:YES];
              return;
            }
            [current complete:@{@"url":current.origin.absoluteString, @"userAgent":agent, @"cookies":session, @"cancelled":@NO, @"verified":@(current.verified), @"cleared":@(current.cleared)} dismiss:YES];
          });
        }];
      });
    }];
  });
}
- (NSArray *)sourceCookies:(NSArray<NSHTTPCookie *> *)cookies {
  NSMutableArray *session = [NSMutableArray new];
  NSString *host = self.origin.host.lowercaseString;
  for (NSHTTPCookie *cookie in cookies) {
    NSString *domain = cookie.domain.lowercaseString;
    // CFNetwork's bare domain is host-only; a leading dot permits subdomains.
    BOOL hostOnly = ![domain hasPrefix:@"."];
    if (!hostOnly) domain = [domain substringFromIndex:1];
    if (!domain.length || [domain hasPrefix:@"."]) continue;
    BOOL matching = [host isEqualToString:domain] ||
      (!hostOnly && [host hasSuffix:[@"." stringByAppendingString:domain]]);
    if (!matching || (cookie.expiresDate && cookie.expiresDate.timeIntervalSinceNow <= 0)) continue;
    NSMutableDictionary *item = [@{@"name":cookie.name, @"value":cookie.value, @"domain":cookie.domain,
      @"hostOnly":@(hostOnly), @"path":cookie.path, @"secure":@(cookie.secure), @"httpOnly":@(cookie.HTTPOnly)} mutableCopy];
    if (cookie.expiresDate) item[@"expiresAt"] = @((long long)(cookie.expiresDate.timeIntervalSince1970 * 1000));
    [session addObject:item];
  }
  return session;
}
- (void)complete:(id)value dismiss:(BOOL)dismiss {
  TachiBrowserOnMain(^{
    if (self.completed) return;
    self.completed = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.observingCookies) { [self.webView.configuration.websiteDataStore.httpCookieStore removeObserver:self]; self.observingCookies = NO; }
    self.completing = NO;
    FlutterResult result = self.completion;
    self.completion = nil;
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    UINavigationController *navigation = self.navigationController;
    navigation.modalInPresentation = NO;
    void (^deliver)(void) = ^{
      if (tachiActiveBrowser == self) tachiActiveBrowser = nil;
      if (result) result(value);
    };
    // Do not release the active session until UIKit has finished removing it;
    // a reentrant open from Flutter can then present on the original screen.
    if (dismiss && navigation.presentingViewController && !navigation.isBeingDismissed) {
      [navigation dismissViewControllerAnimated:YES completion:deliver];
    } else deliver();
  });
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
  [self complete:@{@"cancelled":@YES} dismiss:NO];
}
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  // Programmatic dismissal/window teardown does not call the adaptive
  // presentation delegate. It must still resolve the pending Flutter request.
  if (!self.completed && (self.isBeingDismissed || self.navigationController.isBeingDismissed ||
      (!self.navigationController.presentingViewController && !self.view.window))) {
    // UIKit clears the presentation relationship after this callback. Deliver
    // on the next turn so a reentrant open does not target the closing sheet.
    dispatch_async(dispatch_get_main_queue(), ^{
      [self complete:@{@"cancelled":@YES} dismiss:NO];
    });
  }
}
@end
