/*
 * Endless
 * Copyright (c) 2014-2018 joshua stein <jcs@jcs.org>
 *
 * See LICENSE file for redistribution terms.
 */

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "Bookmark.h"
#import "HTTPSEverywhere.h"
#import "URLInterceptor.h"

#import "UIResponder+FirstResponder.h"

#import "OBRootViewController.h"
#import "OnionBrowser-Swift.h"

@implementation AppDelegate
{
	NSMutableArray *_keyCommands;
	NSMutableArray *_allKeyBindings;
	NSArray *_allCommandsAndKeyBindings;

	BOOL inStartupPhase;
}

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	[self initializeDefaults];

	inStartupPhase = YES;

#ifdef USE_DUMMY_URLINTERCEPTOR
	[NSURLProtocol registerClass:[DummyURLInterceptor class]];
#else
	[URLInterceptor setup];
	[NSURLProtocol registerClass:[URLInterceptor class]];
#endif

	self.hstsCache = [HSTSCache retrieve];
	self.cookieJar = [[CookieJar alloc] init];
	[Bookmark retrieveList];
	
	/* handle per-version upgrades or migrations */
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	long lastBuild = [userDefaults integerForKey:@"last_build"];
	
	NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
	f.numberStyle = NSNumberFormatterDecimalStyle;
	long thisBuild = [[f numberFromString:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"]] longValue];
	
	if (lastBuild != thisBuild) {
		NSLog(@"migrating from build %ld -> %ld", lastBuild, thisBuild);
		[HostSettings migrateFromBuild:lastBuild toBuild:thisBuild];
		
		[userDefaults setInteger:thisBuild forKey:@"last_build"];
		[userDefaults synchronize];
	}
	
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	self.window.backgroundColor = [UIColor groupTableViewBackgroundColor];
	self.window.rootViewController = [[OBRootViewController alloc] init];
	self.window.rootViewController.restorationIdentifier = @"OBRootViewController";

	[self adjustMuteSwitchBehavior];
	
    [Migration migrate];

    Boolean didFirstRunBookmarks = [userDefaults boolForKey:@"did_first_run_bookmarks"];
    if (!didFirstRunBookmarks) {
        if ([[Bookmark list] count] == 0) { // our first run of Onion Browser 2, but did we migrate any bookmarks from previous versions?
            [Bookmark addBookmarkForURLString:@"https://3g2upl4pq6kufc4m.onion/" withName:@"DuckDuckGo Search Engine (onion)"];
            [Bookmark addBookmarkForURLString:@"http://expyuzz4wqqyqhjn.onion/" withName:@"The Tor Project (onion)"];
            [Bookmark addBookmarkForURLString:@"https://freedom.press/" withName:@"Freedom of the Press Foundation"];
            [Bookmark addBookmarkForURLString:@"https://www.propub3r6espa33w.onion/" withName:@"ProPublica (onion)"];
            [Bookmark addBookmarkForURLString:@"https://mobile.nytimes3xbfgragh.onion/" withName:@"New York Times (onion)"];
            [Bookmark addBookmarkForURLString:@"https://m.facebookcorewwwi.onion/" withName:@"Facebook (Onion)"];
            [Bookmark addBookmarkForURLString:@"http://tigas3l7uusztiqu.onion/onionbrowser/" withName:@"Onion Browser official site (onion)"];
            [Bookmark addBookmarkForURLString:@"http://tigas3l7uusztiqu.onion/" withName:@"Mike Tigas, Onion Browser author (onion)"];
            [Bookmark persistList];
        }
        [userDefaults setBool:YES forKey:@"did_first_run_bookmarks"];
        [userDefaults synchronize];
    }

    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	[self.window makeKeyAndVisible];

	if (launchOptions != nil && [launchOptions objectForKey:UIApplicationLaunchOptionsShortcutItemKey]) {
		[self handleShortcut:[launchOptions objectForKey:UIApplicationLaunchOptionsShortcutItemKey]];
	}
	
	return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
	[application ignoreSnapshotOnNextApplicationLaunch];
	[[self webViewController] viewIsNoLongerVisible];

	[BlurredSnapshot create];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	if (![self areTesting]) {
		[HostSettings persist];
		[[self hstsCache] persist];
	}
	
	[TabSecurity handleBackgrounding];

	[application ignoreSnapshotOnNextApplicationLaunch];

    if (OnionManager.shared.state != TorStateStopped) {
        [OnionManager.shared stopTor];
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	[BlurredSnapshot remove];

	[[self webViewController] viewIsVisible];

    if (!inStartupPhase && OnionManager.shared.state != TorStateStarted && OnionManager.shared.state != TorStateConnected) {
        // TODO: actually use UI instead of silently trying to restart Tor.
        [OnionManager.shared startTorWithDelegate:nil];

//        if ([self.window.rootViewController class] != [OBRootViewController class]) {
//                self.window.rootViewController = [[OBRootViewController alloc] init];
//                self.window.rootViewController.restorationIdentifier = @"OBRootViewController";
//        }
    }
    else {
		// During app startup, we don't start Tor from here, but from
		// OBRootViewController in order to catch the delegate callback for progress.
		inStartupPhase = NO;
//        [[self webViewController] viewIsVisible];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	/* this definitely ends our sessions */
	[[self cookieJar] clearAllNonWhitelistedData];
	
	[application ignoreSnapshotOnNextApplicationLaunch];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
#ifdef TRACE
	NSLog(@"[AppDelegate] request to open url: %@", url);
#endif

	if ([[[url scheme] lowercaseString] isEqualToString:@"onionhttp"])
		url = [NSURL URLWithString:[[url absoluteString] stringByReplacingCharactersInRange:NSMakeRange(0, [@"onionhttp" length]) withString:@"http"]];
	else if ([[[url scheme] lowercaseString] isEqualToString:@"onionhttps"])
		url = [NSURL URLWithString:[[url absoluteString] stringByReplacingCharactersInRange:NSMakeRange(0, [@"onionhttps" length]) withString:@"https"]];

	// In case, a modal view controller is overlaying the WebViewController,
	// we need to close it *before* adding a new tab. Otherwise, the UI will
	// be broken on iPhone-X-type devices: The address field will be in the
	// notch area.
	if ([self webViewController].presentedViewController != nil)
	{
		[[self webViewController] dismissViewControllerAnimated:YES completion:^{
			[[self webViewController] addNewTabForURL:url];
		}];
	}
	// If there's no modal view controller, however, the completion block would
	// never be called.
	else {
		[[self webViewController] addNewTabForURL:url];
	}

	return YES;
}

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler
{
	[self handleShortcut:shortcutItem];
	completionHandler(YES);
}

- (BOOL)application:(UIApplication *)application shouldAllowExtensionPointIdentifier:(NSString *)extensionPointIdentifier {
	if ([extensionPointIdentifier isEqualToString:UIApplicationKeyboardExtensionPointIdentifier]) {
		NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
		return [userDefaults boolForKey:@"third_party_keyboards"];
	}
	return YES;
}

- (BOOL)application:(UIApplication *)application shouldRestoreApplicationState:(NSCoder *)coder
{
	if ([self areTesting])
		return NO;
	
	/* if we tried last time and failed, the state might be corrupt */
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	if ([userDefaults objectForKey:STATE_RESTORE_TRY_KEY] != nil) {
		NSLog(@"[AppDelegate] previous startup failed, not restoring application state");
		[userDefaults removeObjectForKey:STATE_RESTORE_TRY_KEY];
		return NO;
	}
	else
		[userDefaults setBool:YES forKey:STATE_RESTORE_TRY_KEY];
	
	[userDefaults synchronize];

	return YES;
}

- (BOOL)application:(UIApplication *)application shouldSaveApplicationState:(NSCoder *)coder
{
	if ([self areTesting])
		return NO;

	return !TabSecurity.isClearOnBackground;
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
	if (!_keyCommands) {
		_keyCommands = [[NSMutableArray alloc] init];
		
		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"[" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Go Back", nil)]];
		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"]" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Go Forward", nil)]];

		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"b" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Show Bookmarks", nil)]];

		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"l" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Focus URL Field", nil)]];

		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"t" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Create New Tab", nil)]];
		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"w" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Close Tab", nil)]];

		for (int i = 1; i <= 10; i++)
			[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:[NSString stringWithFormat:@"%d", (i == 10 ? 0 : i)] modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:[NSString stringWithFormat:NSLocalizedString(@"Switch to Tab %d", nil), i]]];
	}
	
	if (!_allKeyBindings) {
		_allKeyBindings = [[NSMutableArray alloc] init];
		const long modPermutations[] = {
					     UIKeyModifierAlphaShift,
					     UIKeyModifierShift,
					     UIKeyModifierControl,
					     UIKeyModifierAlternate,
					     UIKeyModifierCommand,
					     UIKeyModifierCommand | UIKeyModifierAlternate,
					     UIKeyModifierCommand | UIKeyModifierControl,
					     UIKeyModifierControl | UIKeyModifierAlternate,
					     UIKeyModifierControl | UIKeyModifierCommand,
					     UIKeyModifierControl | UIKeyModifierAlternate | UIKeyModifierCommand,
					     kNilOptions,
		};

		NSString *chars = @"`1234567890-=\b\tqwertyuiop[]\\asdfghjkl;'\rzxcvbnm,./ ";
		for (int j = 0; j < sizeof(modPermutations); j++) {
			for (int i = 0; i < [chars length]; i++) {
				NSString *c = [chars substringWithRange:NSMakeRange(i, 1)];

				[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:c modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			}
		
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
		}
		
		_allCommandsAndKeyBindings = [_keyCommands arrayByAddingObjectsFromArray:_allKeyBindings];
	}
	
	/* if settings are up or something else, ignore shortcuts */
	if (![[self topViewController] isKindOfClass:[WebViewController class]])
		return nil;
	
	id cur = [UIResponder currentFirstResponder];
	if (cur == nil || [NSStringFromClass([cur class]) isEqualToString:@"UIWebView"])
		return _allCommandsAndKeyBindings;
	else {
#ifdef TRACE_KEYBOARD_INPUT
		NSLog(@"[AppDelegate] current first responder is a %@, only passing shortcuts", NSStringFromClass([cur class]));
#endif
		return _keyCommands;
	}
}

- (void)handleKeyboardShortcut:(UIKeyCommand *)keyCommand
{
	if ([keyCommand modifierFlags] == UIKeyModifierCommand) {
		if ([[keyCommand input] isEqualToString:@"b"]) {
			[[self webViewController] showBookmarksForEditing:NO];
			return;
		}

		if ([[keyCommand input] isEqualToString:@"l"]) {
			[[self webViewController] focusUrlField];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"t"]) {
			[[self webViewController] addNewTabForURL:nil forRestoration:NO withAnimation:WebViewTabAnimationDefault withCompletionBlock:^(BOOL finished) {
				[[self webViewController] focusUrlField];
			}];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"w"]) {
			[[self webViewController] removeTab:[[[self webViewController] curWebViewTab] tabIndex]];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"["]) {
			[[[self webViewController] curWebViewTab] goBack];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"]"]) {
			[[[self webViewController] curWebViewTab] goForward];
			return;
		}

		for (int i = 0; i <= 9; i++) {
			if ([[keyCommand input] isEqualToString:[NSString stringWithFormat:@"%d", i]]) {
				[[self webViewController] switchToTab:[NSNumber numberWithInt:(i == 0 ? 9 : i - 1)]];
				return;
			}
		}
	}
	
	if ([self webViewController] && [[self webViewController] curWebViewTab])
		[[[self webViewController] curWebViewTab] handleKeyCommand:keyCommand];
}

- (UIViewController *)topViewController
{
	return [self topViewController:[UIApplication sharedApplication].keyWindow.rootViewController];
}

- (UIViewController *)topViewController:(UIViewController *)rootViewController
{
	if (rootViewController.presentedViewController == nil)
		return rootViewController;
	
	if ([rootViewController.presentedViewController isMemberOfClass:[UINavigationController class]]) {
		UINavigationController *navigationController = (UINavigationController *)rootViewController.presentedViewController;
		UIViewController *lastViewController = [[navigationController viewControllers] lastObject];
		return [self topViewController:lastViewController];
	}
	
	UIViewController *presentedViewController = (UIViewController *)rootViewController.presentedViewController;
	return [self topViewController:presentedViewController];
}

- (void)initializeDefaults
{
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	
	NSString *plistPath = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"InAppSettings.bundle"] stringByAppendingPathComponent:@"Root.inApp.plist"];
	NSDictionary *settingsDictionary = [NSDictionary dictionaryWithContentsOfFile:plistPath];

	for (NSDictionary *pref in [settingsDictionary objectForKey:@"PreferenceSpecifiers"]) {
		NSString *key = [pref objectForKey:@"Key"];
		if (key == nil)
			continue;

		if ([userDefaults objectForKey:key] == NULL) {
			NSObject *val = [pref objectForKey:@"DefaultValue"];
			if (val == nil)
				continue;
			
			[userDefaults setObject:val forKey:key];
#ifdef TRACE
			NSLog(@"[AppDelegate] initialized default preference for %@ to %@", key, val);
#endif
		}
	}
	
	if (![userDefaults synchronize]) {
		NSLog(@"[AppDelegate] failed saving preferences");
		abort();
	}
	
	_searchEngines = [NSMutableDictionary dictionaryWithContentsOfFile:[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"SearchEngines.plist"]];
}

- (BOOL)areTesting
{
	if (NSClassFromString(@"XCTestProbe") != nil) {
		NSLog(@"we are testing");
		return YES;
	}
	else {
		NSDictionary *environment = [[NSProcessInfo processInfo] environment];
		if (environment[@"ARE_UI_TESTING"]) {
			NSLog(@"we are UI testing");
			return YES;
		}
	}
	
	return NO;
}

- (void)handleShortcut:(UIApplicationShortcutItem *)shortcutItem
{
	if ([[shortcutItem type] containsString:@"OpenNewTab"]) {
		[[self webViewController] dismissViewControllerAnimated:YES completion:nil];
		[[self webViewController] addNewTabFromToolbar:nil];
	} else if ([[shortcutItem type] containsString:@"ClearData"]) {
		[[self webViewController] removeAllTabs];
		[[self cookieJar] clearAllNonWhitelistedData];
	} else {
		NSLog(@"[AppDelegate] need to handle action %@", [shortcutItem type]);
	}
}

- (void)adjustMuteSwitchBehavior
{
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

	if ([userDefaults boolForKey:@"mute_with_switch"]) {
		/* setting AVAudioSessionCategoryAmbient will prevent audio from UIWebView from pausing already-playing audio from other apps */
		[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
		[[AVAudioSession sharedInstance] setActive:NO error:nil];
	} else {
		[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
	}
}

@end
