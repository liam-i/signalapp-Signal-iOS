//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSDatabaseMigrationRunner.h"
#import "OWS100RemoveTSRecipientsMigration.h"
#import "OWS102MoveLoggingPreferenceToUserDefaults.h"
#import "OWS103EnableVideoCalling.h"
#import "OWS104CreateRecipientIdentities.h"
#import "OWS105AttachmentFilePaths.h"
#import "OWSDatabaseMigration.h"
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalServiceKit/AppContext.h>

NS_ASSUME_NONNULL_BEGIN

@implementation OWSDatabaseMigrationRunner

- (instancetype)initWithStorageManager:(TSStorageManager *)storageManager
{
    self = [super init];
    if (!self) {
        return self;
    }

    _storageManager = storageManager;

    return self;
}

// This should all migrations which do NOT qualify as safeBlockingMigrations:
- (NSArray<OWSDatabaseMigration *> *)allMigrations
{
    TSStorageManager *storageManager = TSStorageManager.sharedManager;
    return @[
        [[OWS100RemoveTSRecipientsMigration alloc] initWithStorageManager:storageManager],
        [[OWS102MoveLoggingPreferenceToUserDefaults alloc] initWithStorageManager:storageManager],
        [[OWS103EnableVideoCalling alloc] initWithStorageManager:storageManager],
        [[OWS104CreateRecipientIdentities alloc] initWithStorageManager:storageManager],
        [[OWS105AttachmentFilePaths alloc] initWithStorageManager:storageManager],
        [[OWS106EnsureProfileComplete alloc] initWithStorageManager:storageManager]
    ];
}

- (void)assumeAllExistingMigrationsRun
{
    for (OWSDatabaseMigration *migration in self.allMigrations) {
        DDLogInfo(@"%@ Skipping migration on new install: %@", self.logTag, migration);
        [migration save];
    }
}

- (void)runAllOutstanding
{
    [self runMigrations:self.allMigrations];
}

- (void)runMigrations:(NSArray<OWSDatabaseMigration *> *)migrations
{
    OWSAssert(migrations);

    for (OWSDatabaseMigration *migration in migrations) {
        if ([OWSDatabaseMigration fetchObjectWithUniqueID:migration.uniqueId]) {
            DDLogDebug(@"%@ Skipping previously run migration: %@", self.logTag, migration);
        } else {
            DDLogWarn(@"%@ Running migration: %@", self.logTag, migration);
            [migration runUp];
        }
    }
}

@end

NS_ASSUME_NONNULL_END
