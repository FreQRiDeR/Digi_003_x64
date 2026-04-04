#import <Cocoa/Cocoa.h>
#import <PreferencePanes/PreferencePanes.h>

static NSString * const kPanelBundleIdentifier = @"com.avid.panel.{F4CDDB0D-C92E-4914-82D7-178F384992DF}";
static NSString * const kDeviceDomainIdentifier = @"com.avid.device.{F4CDDB0D-C92E-4914-82D7-178F384992DF}";
static NSString * const kDeviceFamilyNameKey = @"Device Family Name";

@interface MAFTrampolinePrefPane003 : NSPreferencePane
@end

@implementation MAFTrampolinePrefPane003

- (nullable NSString *)deviceFamilyNameFromSharedPreferences {
    NSString *preferencesPath = [NSHomeDirectory() stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"Library/Preferences/%@.plist", kDeviceDomainIdentifier]];
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:preferencesPath];
    id deviceName = preferences[kDeviceFamilyNameKey];
    if ([deviceName isKindOfClass:[NSString class]] && [deviceName length] > 0) {
        return (NSString *)deviceName;
    }
    return nil;
}

- (BOOL)launchLegacyControlPanel {
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSURL *appURL = [workspace URLForApplicationWithBundleIdentifier:kPanelBundleIdentifier];
    if (appURL != nil) {
        return [workspace openURL:appURL];
    }

    NSString *embeddedAppPath = [[self bundle] pathForResource:@"Avid003ControlPanel" ofType:@"app"];
    if (embeddedAppPath != nil) {
        NSURL *embeddedURL = [NSURL fileURLWithPath:embeddedAppPath];
        if ([workspace openURL:embeddedURL]) {
            return YES;
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [workspace launchAppWithBundleIdentifier:kPanelBundleIdentifier
                                            options:0x30000
                     additionalEventParamDescriptor:nil
                                   launchIdentifier:nil];
#pragma clang diagnostic pop
}

- (void)showMissingPanelAlertWithDeviceName:(nullable NSString *)deviceName {
    NSBundle *bundle = [self bundle];
    NSString *okButton = [bundle localizedStringForKey:@"OKButton" value:nil table:nil];
    NSString *panelTitle = [bundle localizedStringForKey:@"CanNotOpenPanel" value:nil table:nil];

    NSString *informativeText = nil;
    if (deviceName != nil) {
        NSString *format = [bundle localizedStringForKey:@"CanNotOpenMessageWithName" value:nil table:nil];
        informativeText = [NSString stringWithFormat:format, deviceName, deviceName];
    } else {
        informativeText = [bundle localizedStringForKey:@"CanNotOpenMessageNoName" value:nil table:nil];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:panelTitle];
    [alert setInformativeText:informativeText];
    [alert addButtonWithTitle:okButton];
    [alert runModal];
}

- (void)didSelect {
    if ([self launchLegacyControlPanel]) {
        return;
    }

    NSString *deviceName = [self deviceFamilyNameFromSharedPreferences];
    if (deviceName == nil) {
        deviceName = [[self bundle] objectForInfoDictionaryKey:(NSString *)kCFBundleNameKey];
    }

    [self showMissingPanelAlertWithDeviceName:deviceName];
    [NSApp tryToPerform:@selector(showAll:) with:self];
}

@end
