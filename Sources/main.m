// Auto Hotspot — joins your iPhone's Personal Hotspot when the Mac loses its network,
// and goes back to a saved Wi-Fi when one is in range again. Menu bar app + CLI.
//
//   AutoHotspot              menu bar app (default)
//   AutoHotspot --headless   same watcher, no menu bar icon
//   AutoHotspot --status     print what it sees now and exit
//   AutoHotspot --test       wake the iPhone's hotspot without joining it, then exit
//   AutoHotspot --force      ask the iPhone for its hotspot and join it now, then exit
//
// Uses the private Sharing.framework class SFRemoteHotspotSession (the same one behind
// the Wi-Fi menu's "Personal Hotspot" section). Tested on macOS 26–27.
#import <AppKit/AppKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <dlfcn.h>
#import <sys/file.h>
#import <objc/message.h>

#define LABEL @"io.github.samihalawa.autohotspot"
#define VERSION @"1.0.2"

static NSString *logPath(void){ return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/AutoHotspot.log"]; }
static NSString *plistPath(void){ return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/" LABEL ".plist"]; }
static void (^gOnLog)(NSString *) = nil;

static void L(NSString *f, ...) {
  va_list a; va_start(a,f); NSString *s=[[NSString alloc] initWithFormat:f arguments:a]; va_end(a);
  static NSDateFormatter *d; static dispatch_once_t o; dispatch_once(&o,^{ d=[NSDateFormatter new]; d.dateFormat=@"MM-dd HH:mm:ss"; });
  NSString *line=[NSString stringWithFormat:@"%@ %@\n",[d stringFromDate:NSDate.date],s];
  if(isatty(1)){ printf("%s",line.UTF8String); fflush(stdout); }
  NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:logPath()];
  if(!h){ [[NSFileManager defaultManager] createFileAtPath:logPath() contents:nil attributes:nil]; h=[NSFileHandle fileHandleForWritingAtPath:logPath()]; }
  [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
  if(gOnLog) gOnLog(s);
}

#pragma mark - What the Mac sees

static NSDictionary *globalV4(void){ SCDynamicStoreRef st=SCDynamicStoreCreate(NULL,CFSTR("AutoHotspot"),NULL,NULL);
  NSDictionary *d=(__bridge_transfer NSDictionary*)SCDynamicStoreCopyValue(st,CFSTR("State:/Network/Global/IPv4")); CFRelease(st); return d; }
static BOOL hasLink(void){ NSString *i=globalV4()[@"PrimaryInterface"]; return i.length && ![i hasPrefix:@"utun"]; }
static BOOL onHotspot(void){ return [globalV4()[@"Router"] hasPrefix:@"172.20.10."]; }   // iPhone hotspots always hand out 172.20.10.x
static CWInterface *wifi(void){ return [[CWWiFiClient sharedWiFiClient] interface]; }
static BOOL wifiOn(void){ return wifi().powerOn; }
// Real internet, not just "has an address": dead or captive Wi-Fi fails this.
static BOOL internetOK(void){
  NSURLSessionConfiguration *c=[NSURLSessionConfiguration ephemeralSessionConfiguration]; c.timeoutIntervalForRequest=5; c.timeoutIntervalForResource=6;
  c.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData; c.connectionProxyDictionary=@{};
  __block BOOL ok=NO; dispatch_semaphore_t s=dispatch_semaphore_create(0); NSURLSession *se=[NSURLSession sessionWithConfiguration:c];
  [[se dataTaskWithURL:[NSURL URLWithString:@"https://captive.apple.com/hotspot-detect.html"] completionHandler:^(NSData *d,NSURLResponse *r,NSError *e){
    ok = d && [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] containsString:@"Success"]; dispatch_semaphore_signal(s); }] resume];
  dispatch_semaphore_wait(s,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC)); [se invalidateAndCancel]; return ok; }
static BOOL lidClosedOnBattery(void){
  io_service_t r=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain")); BOOL closed=NO;
  if(r){ CFTypeRef v=IORegistryEntryCreateCFProperty(r,CFSTR("AppleClamshellState"),NULL,0); if(v){ closed=CFBooleanGetValue(v); CFRelease(v);} IOObjectRelease(r); }
  if(!closed) return NO;
  CFTypeRef info=IOPSCopyPowerSourcesInfo(); NSString *t=(__bridge NSString*)IOPSGetProvidingPowerSourceType(info); BOOL batt=[t isEqualToString:@kIOPMBatteryPowerKey]; CFRelease(info); return batt; }

static NSString *run(NSString *path,NSArray *args){ NSTask *t=[NSTask new]; t.launchPath=path; t.arguments=args; NSPipe *p=[NSPipe pipe]; t.standardOutput=p; t.standardError=[NSFileHandle fileHandleWithNullDevice];
  @try{ [t launch]; }@catch(id e){ return @""; } NSData *d=[p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit]; return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]?:@""; }
static void collect(id o,NSMutableDictionary *out){
  if([o isKindOfClass:NSDictionary.class]) for(NSString *k in o){ id v=o[k];
    if([k containsString:@"other_local_wireless_networks"] && [v isKindOfClass:NSArray.class]) for(NSDictionary *n in v){ if(![n isKindOfClass:NSDictionary.class]) continue;
      NSString *nm=n[@"_name"]; NSInteger r=[[n[@"spairport_signal_noise"] description] integerValue];
      // While connected, macOS lists other networks without a signal value: treat "seen, strength unknown" (0) as in range.
      if(nm.length && (!out[nm] || ([out[nm] integerValue]<0 && (r==0 || r>[out[nm] integerValue])))) out[nm]=@(r>0?0:r); }
    else collect(v,out); }
  else if([o isKindOfClass:NSArray.class]) for(id v in o) collect(v,out); }
// A saved, non-hotspot Wi-Fi with decent signal that is in range right now (nil if none).
static NSString *knownWifiInRange(void){
  NSMutableSet *known=[NSMutableSet set];
  for(NSString *l in [run(@"/usr/sbin/networksetup",@[@"-listpreferredwirelessnetworks",wifi().interfaceName?:@"en0"]) componentsSeparatedByString:@"\n"]){
    if(![l hasPrefix:@"\t"]) continue; NSString *n=[l substringFromIndex:1]; if(n.length && ![n hasPrefix:@"iPhone"] && ![n hasPrefix:@"DIRECT-"]) [known addObject:n]; }
  NSData *d=[run(@"/usr/sbin/system_profiler",@[@"SPAirPortDataType",@"-json"]) dataUsingEncoding:NSUTF8StringEncoding]; if(!d.length) return nil;
  NSMutableDictionary *seen=[NSMutableDictionary dictionary]; collect([NSJSONSerialization JSONObjectWithData:d options:0 error:nil],seen);
  NSString *best=nil; for(NSString *n in seen) if([known containsObject:n] && [seen[n] integerValue]>=-72 && (!best || ([seen[n] integerValue]<0 && ([seen[best] integerValue]==0 || [seen[n] integerValue]>[seen[best] integerValue])))) best=n;
  return best; }

#pragma mark - Settings

static NSUserDefaults *prefs(void){ static NSUserDefaults *u; static dispatch_once_t o; dispatch_once(&o,^{ u=NSUserDefaults.standardUserDefaults;
  [u registerDefaults:@{@"paused":@NO,@"deadWifi":@NO,@"returnToWifi":@YES}]; }); return u; }

#pragma mark - Watcher

@interface HS : NSObject
@property id session; @property (atomic) NSArray *devices; @property (atomic) BOOL busy;
@property BOOL join, once, force, saidNoPhone; @property int down, bad, n, fails, hsTicks;
@property NSDate *last, *returnedAt, *noReturnUntil; @property NSString *returnedTo;
@property (atomic) BOOL internet; @property (atomic, copy) NSString *phase; @property (copy) void (^changed)(void);
@end
@implementation HS
- (void)setPhaseAndNotify:(NSString *)p { self.phase=p; if(self.changed) dispatch_async(dispatch_get_main_queue(),self.changed); }
- (NSString *)phoneName { id d=self.devices.firstObject; return d ? [d valueForKey:@"deviceName"] : nil; }
- (void)session:(id)s updatedFoundDevices:(NSArray*)l { self.devices=l; if(self.changed) dispatch_async(dispatch_get_main_queue(),self.changed);
  if(self.once && l.count && !self.busy) [self trigger:self.force why:@"manual"]; }
- (void)trigger:(BOOL)force why:(NSString*)why { [self trigger:force why:why attempt:1]; }
- (void)trigger:(BOOL)force why:(NSString*)why attempt:(int)att {
  id dev=self.devices.firstObject;
  if(!dev){ if(!self.saidNoPhone){ L(@"%@, but no iPhone is nearby",why); self.saidNoPhone=YES; } return; }
  self.busy=YES; self.last=NSDate.date; [self setPhaseAndNotify:@"Connecting to iPhone…"]; L(@"%@ -> asking %@ for its hotspot",why,[dev valueForKey:@"deviceName"]);
  void(^h)(id,id,id,id)=^(id a,id b,id c,id d){
    NSString *ssid=[a isKindOfClass:NSString.class]?a:nil, *pw=[b isKindOfClass:NSString.class]?b:nil;
    if(!ssid){ id err=[d isKindOfClass:NSError.class]?d:([c isKindOfClass:NSError.class]?c:nil);
      L(@"hotspot request %d failed: %@",att,[err localizedDescription]?:@"no answer from the phone");
      if(att<3){ dispatch_async(dispatch_get_global_queue(0,0),^{ sleep(4); [self trigger:force why:@"retry" attempt:att+1]; }); return; }   // the Bluetooth link to the phone often fails on the first try
      self.fails++; self.busy=NO; [self setPhaseAndNotify:nil]; if(self.once) exit(1); return; }
    L(@"hotspot is on: %@",ssid);
    if(!self.join) exit(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ sleep(3);   // let the phone's Wi-Fi come up
      for(int i=0;i<4 && !onHotspot() && (force || !hasLink());i++){
        NSTask *t=[NSTask new]; t.launchPath=@"/usr/sbin/networksetup"; t.arguments=@[@"-setairportnetwork",wifi().interfaceName?:@"en0",ssid,pw?:@""];
        NSPipe *p=[NSPipe pipe]; t.standardOutput=p; t.standardError=p; [t launch]; [t waitUntilExit];
        NSString *o=[[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
        if(o.length) L(@"join attempt %d: %@",i+1,[o stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        sleep(5); }
      BOOL ok = onHotspot() || (!force && hasLink());
      L(ok?(onHotspot()?@"connected to hotspot":@"a normal network came back, staying on it"):@"could not join"); self.fails = ok?0:self.fails+1; self.hsTicks=0;
      if(onHotspot() && self.returnedAt && -self.returnedAt.timeIntervalSinceNow<120){ L(@"%@ did not work out, not trying it again for 15 min",self.returnedTo); self.noReturnUntil=[NSDate dateWithTimeIntervalSinceNow:900]; }
      self.down=0; self.bad=0; self.busy=NO; if(ok) self.internet=YES; [self setPhaseAndNotify:nil]; if(self.once) exit(ok?0:1); });
  };
  ((void(*)(id,SEL,id,id))objc_msgSend)(self.session,NSSelectorFromString(@"enableHotspotForDevice:withCompletionHandler:"),dev,h);
}
- (void)tick {
  if(self.busy) return; self.n++;
  if(!wifiOn()){ self.down=0; self.bad=0; return; }
  BOOL link=hasLink(); NSString *why=nil; BOOL force=NO; BOOL paused=[prefs() boolForKey:@"paused"];
  if(link && onHotspot() && !paused && [prefs() boolForKey:@"returnToWifi"]){       // on the phone: every 2 min look for a saved Wi-Fi to go back to
    if(++self.hsTicks%24==0 && (!self.noReturnUntil || self.noReturnUntil.timeIntervalSinceNow<0)){
      NSString *w=knownWifiInRange();
      if(w){ L(@"saved Wi-Fi %@ is in range -> leaving the hotspot",w); self.returnedAt=NSDate.date; self.returnedTo=w; self.down=0; self.bad=0; self.last=[NSDate dateWithTimeIntervalSinceNow:-20];
        // Join it by name (the hotspot is often first in the preferred list, so a plain disconnect can land back on it).
        run(@"/usr/sbin/networksetup",@[@"-setairportnetwork",wifi().interfaceName?:@"en0",w]); sleep(6);
        if(onHotspot()){ [wifi() disassociate]; sleep(6); }
        L(onHotspot()?@"still on the hotspot":(hasLink()?@"back on Wi-Fi":@"left the hotspot, waiting for Wi-Fi")); [self setPhaseAndNotify:nil]; return; } }
  } else self.hsTicks=0;
  if(!link){ self.bad=0; if(self.internet){ self.internet=NO; [self setPhaseAndNotify:nil]; } if(++self.down>=3) why=@"no network for 15s"; }   // 3 ticks x 5 s
  else { self.down=0;
    if(self.n%3==0){                                                                // probe every 15 s
      BOOL ok=internetOK(); if(ok!=self.internet){ self.internet=ok; [self setPhaseAndNotify:nil]; }
      if(ok){ self.bad=0; self.fails=0; self.saidNoPhone=NO; }
      else if(++self.bad>=2 && !onHotspot() && [prefs() boolForKey:@"deadWifi"]){ why=@"Wi-Fi connected but no internet for 30s"; force=YES; } } }
  if(!why || paused) return;
  NSTimeInterval cool = self.fails>=3 ? 300 : 45;                                   // back off when the phone keeps failing
  if(self.last && -self.last.timeIntervalSinceNow<cool) return;
  [self trigger:force why:why];
}
@end

#pragma mark - Login item (a LaunchAgent the app writes itself)

static NSString *selfPath(void){ return NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath; }
static BOOL loginEnabled(void){ return [[NSFileManager defaultManager] fileExistsAtPath:plistPath()]; }
static void writeLoginItem(NSArray *extraArgs){
  NSMutableArray *args=[NSMutableArray arrayWithObject:selfPath()]; [args addObjectsFromArray:extraArgs?:@[]];
  NSDictionary *p=@{@"Label":LABEL,@"ProgramArguments":args,@"RunAtLoad":@YES,@"KeepAlive":@{@"SuccessfulExit":@NO},@"ThrottleInterval":@5,
    @"ProcessType":@"Interactive",@"StandardErrorPath":logPath()};
  [[NSFileManager defaultManager] createDirectoryAtPath:plistPath().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  [p writeToFile:plistPath() atomically:YES]; }
static NSString *uidDomain(void){ return [NSString stringWithFormat:@"gui/%d",getuid()]; }

#pragma mark - Menu bar

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property HS *hs; @property NSStatusItem *item; @property NSMenu *menu; @property NSString *lastEvent; @property NSDate *lastEventAt;
@end
@implementation App
- (NSMenuItem *)add:(NSString *)t action:(SEL)a key:(NSString *)k { NSMenuItem *i=[self.menu addItemWithTitle:t action:a keyEquivalent:k?:@""]; i.target=self; return i; }
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  self.item=[[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
  self.menu=[NSMenu new]; self.menu.delegate=self; self.menu.autoenablesItems=NO; self.item.menu=self.menu;
  __weak App *w=self; self.hs.changed=^{ [w refreshIcon]; };
  gOnLog=^(NSString *s){ dispatch_async(dispatch_get_main_queue(),^{ w.lastEvent=s; w.lastEventAt=NSDate.date; }); };
  [self refreshIcon];
}
- (void)refreshIcon {
  BOOL paused=[prefs() boolForKey:@"paused"]; NSString *sym, *tip;
  if(self.hs.phase){ sym=@"arrow.triangle.2.circlepath"; tip=self.hs.phase; }
  else if(paused){ sym=@"pause.circle"; tip=@"Auto Hotspot is paused"; }
  else if(!hasLink()){ sym=@"wifi.slash"; tip=@"No network"; }
  else if(onHotspot()){ sym=@"personalhotspot"; tip=@"Online through iPhone hotspot"; }
  else if(!self.hs.internet){ sym=@"wifi.exclamationmark"; tip=@"Wi-Fi without internet"; }
  else { sym=@"wifi"; tip=@"Online through Wi-Fi"; }
  NSImage *img=[NSImage imageWithSystemSymbolName:sym accessibilityDescription:tip]; img.template=YES;
  self.item.button.image=img; self.item.button.toolTip=tip;
}
- (void)menuNeedsUpdate:(NSMenu *)m {
  [m removeAllItems]; [self refreshIcon];
  NSMenuItem *h=[self add:self.item.button.toolTip action:nil key:nil]; h.enabled=NO;
  h.attributedTitle=[[NSAttributedString alloc] initWithString:self.item.button.toolTip attributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:13]}];
  NSString *phone=self.hs.phoneName; NSMenuItem *p=[self add:phone?[NSString stringWithFormat:@"%@ nearby",phone]:@"No iPhone nearby" action:nil key:nil]; p.enabled=NO;
  p.image=[NSImage imageWithSystemSymbolName:phone?@"iphone":@"iphone.slash" accessibilityDescription:nil];
  if(self.lastEvent){ NSDateFormatter *f=[NSDateFormatter new]; f.timeStyle=NSDateFormatterShortStyle; f.dateStyle=NSDateFormatterNoStyle;
    NSString *e=self.lastEvent.length>60?[[self.lastEvent substringToIndex:59] stringByAppendingString:@"…"]:self.lastEvent;
    NSMenuItem *l=[self add:[NSString stringWithFormat:@"%@  %@",[f stringFromDate:self.lastEventAt],e] action:nil key:nil]; l.enabled=NO; }
  [m addItem:NSMenuItem.separatorItem];
  NSMenuItem *c=[self add:@"Connect to iPhone Now" action:@selector(connectNow) key:@"j"]; c.enabled=phone!=nil && !self.hs.busy && !onHotspot();
  [self add:@"Pause Automatic Switching" action:@selector(togglePause) key:nil].state=[prefs() boolForKey:@"paused"];
  [m addItem:NSMenuItem.separatorItem];
  NSMenuItem *o=[self add:@"Options" action:nil key:nil]; NSMenu *sub=[NSMenu new]; sub.autoenablesItems=NO; o.submenu=sub;
  NSMenuItem *(^opt)(NSString*,SEL,BOOL)=^(NSString *t,SEL s,BOOL on){ NSMenuItem *i=[sub addItemWithTitle:t action:s keyEquivalent:@""]; i.target=self; i.state=on; return i; };
  opt(@"Return to Saved Wi-Fi When in Range",@selector(toggleReturn),[prefs() boolForKey:@"returnToWifi"]);
  opt(@"Leave Wi-Fi That Has No Internet",@selector(toggleDead),[prefs() boolForKey:@"deadWifi"]);
  opt(@"Start at Login",@selector(toggleLogin),loginEnabled());
  [sub addItem:NSMenuItem.separatorItem]; opt(@"Open Log",@selector(openLog),NO);
  opt(@"About Auto Hotspot",@selector(about),NO);
  [m addItem:NSMenuItem.separatorItem];
  [self add:@"Quit Auto Hotspot" action:@selector(quit) key:@"q"];
}
- (void)connectNow { HS *h=self.hs; dispatch_async(dispatch_get_global_queue(0,0),^{ h.saidNoPhone=NO; [h trigger:YES why:@"requested from the menu"]; }); }
- (void)togglePause { BOOL v=![prefs() boolForKey:@"paused"]; [prefs() setBool:v forKey:@"paused"]; L(v?@"paused":@"resumed"); [self refreshIcon]; }
- (void)toggleReturn { [prefs() setBool:![prefs() boolForKey:@"returnToWifi"] forKey:@"returnToWifi"]; }
- (void)toggleDead { [prefs() setBool:![prefs() boolForKey:@"deadWifi"] forKey:@"deadWifi"]; }
- (void)toggleLogin { if(loginEnabled()){ [[NSFileManager defaultManager] removeItemAtPath:plistPath() error:nil]; L(@"start at login: off"); }
  else { writeLoginItem(nil); L(@"start at login: on"); } }
- (void)openLog { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:logPath()]]; }
- (void)about { [NSApp activateIgnoringOtherApps:YES]; [NSApp orderFrontStandardAboutPanelWithOptions:@{@"ApplicationName":@"Auto Hotspot",@"ApplicationVersion":VERSION,@"Version":@"",
  @"Credits":[[NSAttributedString alloc] initWithString:@"Joins your iPhone's hotspot when the Mac loses its network.\ngithub.com/samihalawa/mac-auto-hotspot"]}]; }
- (void)quit { L(@"quit from the menu"); exit(0); }   // exit 0: launchd does not restart a clean quit
@end

#pragma mark - main

int main(int argc,char**argv){ @autoreleasepool{
  NSString *m=argc>1?@(argv[1]):@"";
  if([m isEqual:@"--version"]){ printf("%s\n",VERSION.UTF8String); return 0; }
  if([m isEqual:@"--help"]||[m isEqual:@"-h"]){ printf("usage: AutoHotspot [--headless|--status|--test|--force|--version]\n"); return 0; }
  if([m isEqual:@"--status"]){ printf("link=%d internet=%d onHotspot=%d wifiOn=%d lidClosedOnBattery=%d paused=%d loginItem=%d knownWifiInRange=%s\n",
      hasLink(),internetOK(),onHotspot(),wifiOn(),lidClosedOnBattery(),[prefs() boolForKey:@"paused"],loginEnabled(),knownWifiInRange().UTF8String?:"-"); return 0; }
  BOOL once=[m isEqual:@"--test"]||[m isEqual:@"--force"], headless=[m isEqual:@"--headless"];
  BOOL underLaunchd=[NSProcessInfo.processInfo.environment[@"XPC_SERVICE_NAME"] isEqual:LABEL];
  if(!once){
    // Opened from Finder while the login item exists: hand over to launchd so only one copy runs.
    if(!underLaunchd && m.length==0 && loginEnabled()){
      if(![run(@"/bin/launchctl",@[@"print",[NSString stringWithFormat:@"%@/%@",uidDomain(),LABEL]]) length]) run(@"/bin/launchctl",@[@"bootstrap",uidDomain(),plistPath()]);
      else run(@"/bin/launchctl",@[@"kickstart",[NSString stringWithFormat:@"%@/%@",uidDomain(),LABEL]]);
      return 0; }
    // First launch from Finder: create the login item, then hand over.
    if(!underLaunchd && m.length==0 && ![[NSUserDefaults standardUserDefaults] boolForKey:@"launchedBefore"] && [selfPath() containsString:@".app/"]){
      [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"launchedBefore"];
      writeLoginItem(nil); run(@"/bin/launchctl",@[@"bootstrap",uidDomain(),plistPath()]); L(@"installed login item"); return 0; }
    int fd=open([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/.AutoHotspot.lock"] fileSystemRepresentation],O_CREAT|O_RDWR,0644);
    if(fd<0 || flock(fd,LOCK_EX|LOCK_NB)!=0){ fprintf(stderr,"Auto Hotspot is already running\n"); return 0; } }
  dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing",RTLD_NOW);
  HS *h=[HS new]; h.once=once; h.join=![m isEqual:@"--test"]; h.force=[m isEqual:@"--force"]; h.internet=YES;
  h.session=[NSClassFromString(@"SFRemoteHotspotSession") new]; if(!h.session){ L(@"hotspot API missing on this macOS"); return 2; }
  [h.session setValue:h forKey:@"delegate"]; ((void(*)(id,SEL))objc_msgSend)(h.session,NSSelectorFromString(@"startBrowsing"));
  static App *app; static dispatch_source_t keep;
  if(once){ dispatch_after(dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC),dispatch_get_main_queue(),^{ L(@"timeout: no iPhone found"); exit(1); }); [[NSRunLoop mainRunLoop] run]; return 0; }
  L(@"watching (v%@%@)",VERSION,headless?@", headless":@"");
  static id act; act=[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"network watcher"];
  dispatch_queue_t q=dispatch_queue_create("tick",DISPATCH_QUEUE_SERIAL);
  keep=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,q); dispatch_source_set_timer(keep,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),5*NSEC_PER_SEC,NSEC_PER_SEC);
  dispatch_source_set_event_handler(keep,^{ [h tick]; }); dispatch_resume(keep);
  // After wake (lid opened somewhere new) react fast and forget old cooldowns.
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil usingBlock:^(NSNotification *n){
    dispatch_async(q,^{ L(@"woke up"); h.last=nil; h.fails=0; h.saidNoPhone=NO; h.down=1; h.bad=1; h.n=1; }); }];
  if(headless){ [[NSRunLoop mainRunLoop] run]; return 0; }
  NSApplication *a=[NSApplication sharedApplication]; [a setActivationPolicy:NSApplicationActivationPolicyAccessory];
  app=[App new]; app.hs=h; a.delegate=app; [a run]; } return 0; }
