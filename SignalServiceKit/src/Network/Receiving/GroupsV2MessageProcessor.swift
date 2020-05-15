//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

private struct IncomingGroupsV2MessageJobInfo {
    let job: IncomingGroupsV2MessageJob
    var envelope: SSKProtoEnvelope?
    var groupContext: SSKProtoGroupContextV2?
    var groupContextInfo: GroupV2ContextInfo?
}

// MARK: -

class IncomingGroupsV2MessageQueue: NSObject {

    // MARK: - Dependencies

    private var messageManager: OWSMessageManager {
        return SSKEnvironment.shared.messageManager
    }

    private var tsAccountManager: TSAccountManager {
        return SSKEnvironment.shared.tsAccountManager
    }

    private var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    private var groupsV2: GroupsV2Swift {
        return SSKEnvironment.shared.groupsV2 as! GroupsV2Swift
    }

    private var groupV2Updates: GroupV2UpdatesSwift {
        return SSKEnvironment.shared.groupV2Updates as! GroupV2UpdatesSwift
    }

    private var blockingManager: OWSBlockingManager {
        return SSKEnvironment.shared.blockingManager
    }

    private var notificationsManager: NotificationsProtocol {
        return SSKEnvironment.shared.notificationsManager
    }

    // MARK: -

    private let finder = GRDBGroupsV2MessageJobFinder()
    // This property should only be accessed on serialQueue.
    private var isDrainingQueue = false
    private var isAppInBackground = AtomicBool(false)

    private typealias BatchCompletionBlock = ([IncomingGroupsV2MessageJob], Bool, SDSAnyWriteTransaction) -> Void

    override init() {
        super.init()

        SwiftSingletons.register(self)

        observeNotifications()

        // Start processing.
        drainQueueWhenReady()
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillEnterForeground),
                                               name: .OWSApplicationWillEnterForeground,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: .OWSApplicationDidEnterBackground,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registrationStateDidChange),
                                               name: .registrationStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(webSocketStateDidChange),
                                               name: .webSocketStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reachabilityChanged),
                                               name: SSKReachability.owsReachabilityDidChange,
                                               object: nil)
    }

    // MARK: - Notifications

    @objc func applicationWillEnterForeground() {
        AssertIsOnMainThread()

        isAppInBackground.set(false)
    }

    @objc func applicationDidEnterBackground() {
        AssertIsOnMainThread()

        isAppInBackground.set(true)
    }

    @objc func registrationStateDidChange() {
        AssertIsOnMainThread()

        drainQueueWhenReady()
    }

    @objc func webSocketStateDidChange() {
        AssertIsOnMainThread()

        drainQueueWhenReady()
    }

    @objc func reachabilityChanged() {
        AssertIsOnMainThread()

        drainQueueWhenReady()
    }

    // MARK: -

    private let serialQueue: DispatchQueue = DispatchQueue(label: "org.whispersystems.message.groupv2")

    fileprivate func enqueue(envelopeData: Data,
                             plaintextData: Data?,
                             groupId: Data,
                             wasReceivedByUD: Bool,
                             transaction: SDSAnyWriteTransaction) {

        // We need to persist the decrypted envelope data ASAP to prevent data loss.
        finder.addJob(envelopeData: envelopeData,
                      plaintextData: plaintextData,
                      groupId: groupId,
                      wasReceivedByUD: wasReceivedByUD,
                      transaction: transaction.unwrapGrdbWrite)
    }

    fileprivate func drainQueueWhenReady() {
        guard CurrentAppContext().shouldProcessIncomingMessages else {
            return
        }
        AppReadiness.runNowOrWhenAppDidBecomeReadyPolite {
            self.drainQueue()
        }
    }

    private func drainQueue(retryDelayAfterFailure: TimeInterval = 1.0) {
        guard AppReadiness.isAppReady() || CurrentAppContext().isRunningTests else {
            owsFailDebug("App is not ready.")
            return
        }
        guard CurrentAppContext().shouldProcessIncomingMessages else {
            return
        }
        guard tsAccountManager.isRegisteredAndReady else {
            return
        }

        serialQueue.async {
            guard !self.isDrainingQueue else {
                return
            }
            self.isDrainingQueue = true
            self.drainQueueWorkStep(retryDelayAfterFailure: retryDelayAfterFailure)
        }
    }

    private func drainQueueWorkStep(retryDelayAfterFailure: TimeInterval = 1.0) {
        assertOnQueue(serialQueue)

        guard !DebugFlags.suppressBackgroundActivity else {
            // Don't process queues.
            return
        }
        guard RemoteConfig.groupsV2IncomingMessages else {
            // Don't process this queue.
            return
        }

        // We want a value that is just high enough to yield perf benefits.
        let kIncomingMessageBatchSize: UInt = 32
        // If the app is in the background, use batch size of 1.
        // This reduces the cost of being interrupted and rolled back if
        // app is suspended.
        let batchSize: UInt = isAppInBackground.get() ? 1 : kIncomingMessageBatchSize

        let batchJobs = databaseStorage.read { transaction in
            return self.finder.nextJobs(batchSize: batchSize, transaction: transaction.unwrapGrdbRead)
        }
        guard batchJobs.count > 0 else {
            self.isDrainingQueue = false
            Logger.verbose("Queue is drained")
            NotificationCenter.default.postNotificationNameAsync(GroupsV2MessageProcessor.didFlushGroupsV2MessageQueue, object: nil)
            return
        }

        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "\(#function)")

        let completion: BatchCompletionBlock = { (processedJobs, shouldWaitBeforeRetrying, transaction) in
            // NOTE: This transaction is the same transaction as the transaction
            //       passed to processJobs() in the "sync" case but is a different
            //       transaction in the "async" case.

            if shouldWaitBeforeRetrying {
                Logger.warn("shouldWaitBeforeRetrying")
            }

            let uniqueIds = processedJobs.map { $0.uniqueId }
            self.finder.removeJobs(withUniqueIds: uniqueIds,
                                   transaction: transaction.unwrapGrdbWrite)

            let jobCount: UInt = self.finder.jobCount(transaction: transaction)

            Logger.verbose("completed \(processedJobs.count)/\(batchJobs.count) jobs. \(jobCount) jobs left.")

            transaction.addAsyncCompletion {
                assert(backgroundTask != nil)
                backgroundTask = nil

                if shouldWaitBeforeRetrying {
                    // Retry with exponential backoff.
                    self.serialQueue.async {
                        // After successfully processing a batch drainQueueWorkStep()
                        // calls itself to process the next batch, if any.
                        // The isDrainingQueue flag is cleared when all batches have
                        // been processed.
                        //
                        // After failures, we clear isDrainingQueue immediately and
                        // call drainQueue(), not drainQueueWorkStep() after a delay.
                        // That allows us to kick off another batch immediately if
                        // reachability changes, etc.
                        self.isDrainingQueue = false
                        self.serialQueue.asyncAfter(deadline: DispatchTime.now() + retryDelayAfterFailure) {
                            self.drainQueue(retryDelayAfterFailure: retryDelayAfterFailure * 2)
                        }
                    }
                } else {
                    // Wait always a bit in hopes of increasing the size of the next batch.
                    // This delay won't affect the first message to arrive when this queue is idle,
                    // so by definition we're receiving more than one message and can benefit from
                    // batching.
                    let batchSpacingSeconds: TimeInterval = 0.5
                    self.serialQueue.asyncAfter(deadline: DispatchTime.now() + batchSpacingSeconds) {
                        self.drainQueueWorkStep()
                    }
                }
            }
        }

        databaseStorage.write { transaction in
            self.processJobs(jobs: batchJobs, transaction: transaction, completion: completion)
        }
    }

    private func jobInfo(forJob job: IncomingGroupsV2MessageJob,
                         transaction: SDSAnyReadTransaction) -> IncomingGroupsV2MessageJobInfo {
        var jobInfo = IncomingGroupsV2MessageJobInfo(job: job)
        guard let envelope = job.envelope else {
            owsFailDebug("Missing envelope.")
            return jobInfo
        }
        jobInfo.envelope = envelope
        guard let groupContext = GroupsV2MessageProcessor.groupContextV2(forEnvelope: envelope, plaintextData: job.plaintextData) else {
            owsFailDebug("Missing group context.")
            return jobInfo
        }
        jobInfo.groupContext = groupContext
        do {
            jobInfo.groupContextInfo = try groupsV2.groupV2ContextInfo(forMasterKeyData: groupContext.masterKey)
        } catch {
            owsFailDebug("Invalid group context: \(error).")
            return jobInfo
        }

        return jobInfo
    }

    private func canJobBeDiscarded(jobInfo: IncomingGroupsV2MessageJobInfo,
                                   shouldDiscardIfNotAMember: Bool = false,
                                   transaction: SDSAnyReadTransaction) -> Bool {
        // We want to discard asap to avoid problems with batching.
        guard let envelope = jobInfo.envelope else {
            owsFailDebug("Missing envelope.")
            return true
        }
        guard let groupContext = jobInfo.groupContext else {
            owsFailDebug("Missing groupContext.")
            return true
        }
        guard let groupContextInfo = jobInfo.groupContextInfo else {
            owsFailDebug("Missing groupContextInfo.")
            return true
        }
        guard let sourceAddress = envelope.sourceAddress,
            sourceAddress.isValid else {
                owsFailDebug("Invalid source address.")
                return true
        }
        guard !blockingManager.isAddressBlocked(sourceAddress) &&
            !blockingManager.isGroupIdBlocked(groupContextInfo.groupId) else {
                Logger.info("Discarding blocked envelope.")
                return true
        }
        guard groupContext.hasRevision else {
            Logger.info("Missing revision.")
            return true
        }

        // We need to pre-process all incoming envelopes; they might change
        // our group state.
        //
        // But we should only pass envelopes to the MessageManager for
        // processing if they correspond to v2 groups of which we are a
        // non-pending member.
        if shouldDiscardIfNotAMember {
            guard let localAddress = self.tsAccountManager.localAddress else {
                owsFailDebug("Missing localAddress.")
                return true
            }
            guard let groupThread = TSGroupThread.fetch(groupId: groupContextInfo.groupId,
                                                        transaction: transaction) else {
                                                            // The user might have just deleted the thread
                                                            // but this race should be extremely rare.
                                                            // Usually this should indicate a bug.
                                                            owsFailDebug("Missing thread.")
                                                            return true
            }
            guard groupThread.groupModel.groupMembership.isNonPendingMember(localAddress) else {
                // * Local user might have just left the group.
                // * Local user may have just learned that we were removed from the group.
                // * Local user might be a pending member with an invite.
                Logger.warn("Discarding envelope; local user is not an active group member.")
                return true
            }
            guard groupThread.groupModel.groupMembership.isNonPendingMember(sourceAddress) else {
                // * The sender might have just left the group.
                Logger.warn("Discarding envelope; sender is not an active group member.")
                return true
            }
        }

        return false
    }

    // Like non-v2 group messages, we want to do batch processing
    // wherever possible for perf reasons (to reduce view updates).
    // We should be able to mostly do that. However, in some cases
    // we need to update the group  before we can process the
    // message. Such messages should be processed in a batch
    // of their own.
    //
    // Therefore, when trying to process we try to process either:
    //
    // * The first N messages that can be processed "without update".
    // * The first message, which has to be processed "with update".
    //
    // Which type of batch we try to process is determined by the
    // message at the head of the queue.
    private func canJobBeProcessedWithoutUpdate(jobInfo: IncomingGroupsV2MessageJobInfo,
                                                transaction: SDSAnyReadTransaction) -> Bool {
        if canJobBeDiscarded(jobInfo: jobInfo, transaction: transaction) {
            return true
        }
        guard let groupContext = jobInfo.groupContext else {
            owsFailDebug("Missing groupContext.")
            return true
        }
        guard let groupContextInfo = jobInfo.groupContextInfo else {
            owsFailDebug("Missing groupContextInfo.")
            return true
        }
        let groupId = groupContextInfo.groupId
        guard let groupThread = TSGroupThread.fetch(groupId: groupId, transaction: transaction) else {
            return false
        }
        guard let groupModel = groupThread.groupModel as? TSGroupModelV2 else {
            owsFailDebug("Invalid group model.")
            return false
        }
        let messageRevision = groupContext.revision
        let modelRevision = groupModel.revision
        if messageRevision <= modelRevision {
            return true
        }
        // The incoming message indicates that there is a new group revision.
        // We'll update our group model in a standalone batch using either
        // the change proto embedded in the group context or by fetching
        // latest state from the service.
        return false
    }

    // NOTE: This method might do its work synchronously (in the "no update" case)
    //       or asynchronously (in the "update" case).  It may only process
    //       a subset of the jobs.
    private func processJobs(jobs: [IncomingGroupsV2MessageJob],
                             transaction: SDSAnyWriteTransaction,
                             completion: @escaping BatchCompletionBlock) {

        // 1. Gather info for each job.
        // 2. Decide whether we'll process 1 "update" job or N "no update" jobs.
        //
        // "Update" jobs may require interaction with the service, namely
        // fetching group changes or latest group state.
        var isUpdateBatch = false
        var jobInfos = [IncomingGroupsV2MessageJobInfo]()
        for job in jobs {
            let jobInfo = self.jobInfo(forJob: job, transaction: transaction)
            let canJobBeProcessedWithoutUpdate = self.canJobBeProcessedWithoutUpdate(jobInfo: jobInfo, transaction: transaction)
            if !canJobBeProcessedWithoutUpdate {
                if jobInfos.count > 0 {
                    // Can't add "update" job to "no update" batch, abort and process jobs
                    // already added to batch.
                    break
                }
                // Update batches should only contain a single job.
                isUpdateBatch = true
                jobInfos.append(jobInfo)
                break
            }
            jobInfos.append(jobInfo)
        }

        if isUpdateBatch {
            assert(jobInfos.count == 1)
            guard let jobInfo = jobInfos.first else {
                owsFailDebug("Missing job")
                completion([], false, transaction)
                return
            }
            updateGroupAndProcessJobAsync(jobInfo: jobInfo, completion: completion)
        } else {
            let processedJobs = performLocalProcessingSync(jobInfos: jobInfos,
                                                           transaction: transaction)
            completion(processedJobs, false, transaction)
        }
    }

    private func performLocalProcessingSync(jobInfos: [IncomingGroupsV2MessageJobInfo],
                                            transaction: SDSAnyWriteTransaction) -> [IncomingGroupsV2MessageJob] {
        guard jobInfos.count > 0 else {
            owsFailDebug("Missing jobInfos.")
            return []
        }

        let reportFailure = { (transaction: SDSAnyWriteTransaction) in
            // TODO: Add analytics.
            let errorMessage = ThreadlessErrorMessage.corruptedMessageInUnknownThread()
            self.notificationsManager.notifyUser(for: errorMessage, transaction: transaction)
        }

        var processedJobs = [IncomingGroupsV2MessageJob]()
        for jobInfo in jobInfos {
            let job = jobInfo.job

            if canJobBeDiscarded(jobInfo: jobInfo,
                                 shouldDiscardIfNotAMember: true,
                                 transaction: transaction) {
                // Do nothing.
                Logger.verbose("Discarding job.")
            } else {
                guard let envelope = jobInfo.envelope else {
                    owsFailDebug("Missing envelope.")
                    reportFailure(transaction)
                    continue
                }
                if !self.messageManager.processEnvelope(envelope,
                                                        plaintextData: job.plaintextData,
                                                        wasReceivedByUD: job.wasReceivedByUD,
                                                        transaction: transaction) {
                    reportFailure(transaction)
                }
            }
            processedJobs.append(job)

            if isAppInBackground.get() {
                // If the app is in the background, stop processing this batch.
                //
                // Since this check is done after processing jobs, we'll continue
                // to process jobs in batches of 1.  This reduces the cost of
                // being interrupted and rolled back if app is suspended.
                break
            }
        }
        return processedJobs
    }

    private enum UpdateOutcome {
        case successShouldProcess
        case failureShouldDiscard
        case failureShouldRetry
        case failureShouldFailoverToService
    }

    private func updateGroupAndProcessJobAsync(jobInfo: IncomingGroupsV2MessageJobInfo,
                                               completion: @escaping BatchCompletionBlock) {

        firstly {
            updateGroupPromise(jobInfo: jobInfo)
        }.map(on: DispatchQueue.global()) { (updateOutcome: UpdateOutcome) throws -> Void in
            switch updateOutcome {
            case .successShouldProcess:
                self.databaseStorage.write { transaction in
                    let processedJobs = self.performLocalProcessingSync(jobInfos: [jobInfo], transaction: transaction)
                    completion(processedJobs, false, transaction)
                }
            case .failureShouldDiscard:
                throw GroupsV2Error.shouldDiscard
            case .failureShouldRetry:
                throw GroupsV2Error.shouldRetry
            case .failureShouldFailoverToService:
                owsFailDebug("Invalid embeddedUpdateOutcome: .failureShouldFailoverToService.")
                throw GroupsV2Error.shouldDiscard
            }
        }.recover(on: .global()) { error in
            self.databaseStorage.write { transaction in
                if self.isRetryableError(error) {
                    Logger.warn("Error: \(error)")
                    // Retry
                    // _Do not_ include the job in the processed jobs.
                    // _Do_ wait before retrying.
                    completion([], true, transaction)
                } else {
                    owsFailDebug("Discarding unprocess-able message: \(error)")

                    // Do not retry
                    // _Do_ include the job in the processed jobs.
                    //      It will be discarded.
                    // _Do not_ wait before retrying.
                    completion([jobInfo.job], false, transaction)
                }
            }
        }.retainUntilComplete()
    }

    private func updateGroupPromise(jobInfo: IncomingGroupsV2MessageJobInfo) -> Promise<UpdateOutcome> {
        // First, we try to update the group locally using changes embedded in
        // the group context (if any).
        firstly {
            return self.tryToUpdateUsingEmbeddedGroupUpdate(jobInfo: jobInfo)
        }.recover(on: .global()) { _ in
            owsFailDebug("tryToUpdateUsingEmbeddedGroupUpdate should never fail.")
            return Guarantee.value(UpdateOutcome.failureShouldFailoverToService)
        }.then(on: DispatchQueue.global()) { (embeddedUpdateOutcome: UpdateOutcome) -> Promise<UpdateOutcome> in
            if embeddedUpdateOutcome == .failureShouldFailoverToService {
                return self.tryToUpdateUsingService(jobInfo: jobInfo)
            } else {
                return Promise.value(embeddedUpdateOutcome)
            }
        }
    }

    // We only try to apply one embedded update per batch.
    //
    // If applying the embedded update fails, we fail
    // over to fetching latest state from service.
    //
    // This method should:
    //
    // * Return .successShouldProcess if message processing should proceed. Either:
    //   * ...the group didn't need to be updated (some other component beat us to it).
    //   * ...the group was successfully updated to the target revision.
    // * Return .failureShouldFailoverToService if the group could not be updated
    //   to the target revision and we should fail over to fetching group changes
    //   and/or latest group state from the service.
    // * Return .failureShouldDiscard if this message should be discarded.
    //
    // This method should never return .failureShouldRetry.
    private func tryToUpdateUsingEmbeddedGroupUpdate(jobInfo: IncomingGroupsV2MessageJobInfo) -> Promise<UpdateOutcome> {
        let (promise, resolver) = Promise<UpdateOutcome>.pending()
        DispatchQueue.global().async {
            guard let groupContextInfo = jobInfo.groupContextInfo,
                let groupContext = jobInfo.groupContext else {
                    owsFailDebug("Missing jobInfo properties.")
                    return resolver.fulfill(.failureShouldDiscard)
            }
            let groupId = groupContextInfo.groupId
            guard GroupManager.isValidGroupId(groupId, groupsVersion: .V2) else {
                owsFailDebug("Invalid groupId.")
                return resolver.fulfill(.failureShouldDiscard)
            }
            let thread = self.databaseStorage.read { transaction in
                return TSGroupThread.fetch(groupId: groupId, transaction: transaction)
            }
            guard let groupThread = thread else {
                // We might be learning of a group for the first time
                // in which case we should fetch current group state from the
                // service.
                return resolver.fulfill(.failureShouldFailoverToService)
            }
            guard let oldGroupModel = groupThread.groupModel as? TSGroupModelV2 else {
                owsFailDebug("Invalid group model.")
                return resolver.fulfill(.failureShouldDiscard)
            }
            guard groupContext.hasRevision else {
                owsFailDebug("Missing revision.")
                return resolver.fulfill(.failureShouldDiscard)
            }
            let contextRevision = groupContext.revision
            guard contextRevision > oldGroupModel.revision else {
                // Group is already updated.
                // No need to apply embedded change from the group context; it is obsolete.
                // This can happen due to races.
                return resolver.fulfill(.successShouldProcess)
            }
            guard contextRevision == oldGroupModel.revision + 1 else {
                // We can only apply embedded changes if we're behind exactly
                // one revision.
                return resolver.fulfill(.failureShouldFailoverToService)
            }
            guard FeatureFlags.groupsV2processProtosInGroupUpdates else {
                return resolver.fulfill(.failureShouldFailoverToService)
            }
            guard let changeActionsProtoData = groupContext.groupChange else {
                // No embedded group change.
                return resolver.fulfill(.failureShouldFailoverToService)
            }

            DispatchQueue.global().async(.promise) {
                // We need to verify the signatures because these protos came from
                // another client, not the service.
                return try self.groupsV2.parseAndVerifyChangeActionsProto(changeActionsProtoData,
                                                                          ignoreSignature: false)
            }.then(on: .global()) { (changeActionsProto: GroupsProtoGroupChangeActions) throws -> Promise<TSGroupThread> in
                guard changeActionsProto.revision == contextRevision else {
                    throw OWSAssertionError("Embeded change proto revision doesn't match context revision.")
                }
                return try self.groupsV2.updateGroupWithChangeActions(groupId: oldGroupModel.groupId,
                                                                      changeActionsProto: changeActionsProto,
                                                                      ignoreSignature: false,
                                                                      groupSecretParamsData: oldGroupModel.secretParamsData)
            }.map(on: .global()) { (updatedGroupThread: TSGroupThread) throws -> Void in
                guard let updatedGroupModel = updatedGroupThread.groupModel as? TSGroupModelV2 else {
                    owsFailDebug("Invalid group model.")
                    return resolver.fulfill(.failureShouldFailoverToService)
                }
                guard updatedGroupModel.revision >= contextRevision else {
                    owsFailDebug("Invalid revision.")
                    return resolver.fulfill(.failureShouldFailoverToService)
                }
                guard updatedGroupModel.revision == contextRevision else {
                    // We expect the embedded changes to update us to the target
                    // revision.  If we update past that, assert but proceed in production.
                    owsFailDebug("Unexpected revision.")
                    return resolver.fulfill(.successShouldProcess)
                }
                Logger.info("Successfully applied embedded change proto from group context.")
                return resolver.fulfill(.successShouldProcess)
            }.catch(on: .global()) { error in
                if self.isRetryableError(error) {
                    Logger.warn("Error: \(error)")
                    return resolver.fulfill(.failureShouldRetry)
                } else {
                    owsFailDebug("Error: \(error)")
                    return resolver.fulfill(.failureShouldFailoverToService)
                }
            }.retainUntilComplete()
        }
        return promise
    }

    private func tryToUpdateUsingService(jobInfo: IncomingGroupsV2MessageJobInfo) -> Promise<UpdateOutcome> {
        guard let groupContextInfo = jobInfo.groupContextInfo,
            let groupContext = jobInfo.groupContext else {
                owsFailDebug("Missing jobInfo properties.")
                return Promise(error: GroupsV2Error.shouldDiscard)
        }

        // See GroupV2UpdatesImpl.
        // This will try to update the group using incremental "changes" but
        // failover to using a "snapshot".
        let groupUpdateMode = GroupUpdateMode.upToSpecificRevisionImmediately(upToRevision: groupContext.revision)
        return firstly {
            self.groupV2Updates.tryToRefreshV2GroupThread(groupId: groupContextInfo.groupId,
                                                          groupSecretParamsData: groupContextInfo.groupSecretParamsData,
                                                          groupUpdateMode: groupUpdateMode)
        }.map(on: .global()) { (_) in
            return UpdateOutcome.successShouldProcess
        }.recover(on: .global()) { error -> Guarantee<UpdateOutcome> in
            if self.isRetryableError(error) {
                Logger.warn("error: \(type(of: error)) \(error)")
                return Guarantee.value(UpdateOutcome.failureShouldRetry)
            }

            owsFailDebug("error: \(type(of: error)) \(error)")
            return Guarantee.value(UpdateOutcome.failureShouldDiscard)
        }
    }

    private func isRetryableError(_ error: Error) -> Bool {
        if IsNetworkConnectivityFailure(error) {
            return true
        }
        if let statusCode = error.httpStatusCode {
            if statusCode == 401 ||
               (500 <= statusCode && statusCode <= 599) {
                return true
            }
        }
        switch error {
        case GroupsV2Error.timeout, GroupsV2Error.shouldRetry:
            return true
        default:
            return false
        }
    }

    func hasPendingJobs(transaction: SDSAnyReadTransaction) -> Bool {
        return self.finder.jobCount(transaction: transaction) > 0
    }
}

// MARK: -

@objc
public class GroupsV2MessageProcessor: NSObject {

    // MARK: - Dependencies

    private var groupsV2: GroupsV2Swift {
        return SSKEnvironment.shared.groupsV2 as! GroupsV2Swift
    }

    // MARK: - 

    @objc
    public static let didFlushGroupsV2MessageQueue = Notification.Name("didFlushGroupsV2MessageQueue")

    private let processingQueue = IncomingGroupsV2MessageQueue()

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)

        processingQueue.drainQueueWhenReady()
    }

    // MARK: -

    @objc
    public func enqueue(envelopeData: Data,
                        plaintextData: Data?,
                        envelope: SSKProtoEnvelope,
                        wasReceivedByUD: Bool,
                        transaction: SDSAnyWriteTransaction) {
        guard envelopeData.count > 0 else {
            owsFailDebug("Empty envelope.")
            return
        }

        guard RemoteConfig.groupsV2IncomingMessages else {
            // Discard envelope.
            return
        }

        guard let groupId = groupId(forEnvelope: envelope, plaintextData: plaintextData) else {
            owsFailDebug("Missing or invalid group id")
            return
        }

        // We need to persist the decrypted envelope data ASAP to prevent data loss.
        processingQueue.enqueue(envelopeData: envelopeData,
                                plaintextData: plaintextData,
                                groupId: groupId,
                                wasReceivedByUD: wasReceivedByUD,
                                transaction: transaction)

        // The new envelope won't be visible to the finder until this transaction commits,
        // so drainQueue in the transaction completion.
        transaction.addAsyncCompletion {
            self.processingQueue.drainQueueWhenReady()
        }
    }

    private func groupId(forEnvelope envelope: SSKProtoEnvelope,
                         plaintextData: Data?) -> Data? {
        guard let groupContext = GroupsV2MessageProcessor.groupContextV2(forEnvelope: envelope,
                                                                         plaintextData: plaintextData) else {
                                                                            owsFailDebug("Invalid envelope.")
                                                                            return nil
        }
        do {
            let groupContextInfo = try groupsV2.groupV2ContextInfo(forMasterKeyData: groupContext.masterKey)
            return groupContextInfo.groupId
        } catch {
            owsFailDebug("Invalid group context: \(error).")
            return nil
        }
    }

    @objc
    public class func isGroupsV2Message(envelope: SSKProtoEnvelope?,
                                        plaintextData: Data?) -> Bool {
        return groupContextV2(forEnvelope: envelope,
                              plaintextData: plaintextData) != nil
    }

    @objc
    public class func groupContextV2(forEnvelope envelope: SSKProtoEnvelope?,
                                     plaintextData: Data?) -> SSKProtoGroupContextV2? {
        guard let envelope = envelope else {
            return nil
        }
        guard let plaintextData = plaintextData,
            plaintextData.count > 0 else {
                return nil
        }
        guard envelope.content != nil else {
            return nil
        }

        let contentProto: SSKProtoContent
        do {
            contentProto = try SSKProtoContent.parseData(plaintextData)
        } catch {
            owsFailDebug("could not parse proto: \(error)")
            return nil
        }

        if let groupV2 = contentProto.dataMessage?.groupV2 {
            return groupV2
        } else if let groupV2 = contentProto.syncMessage?.sent?.message?.groupV2 {
            return groupV2
        } else {
            return nil
        }
    }

    @objc
    public func hasPendingJobs(transaction: SDSAnyReadTransaction) -> Bool {
        return processingQueue.hasPendingJobs(transaction: transaction)
    }
}
