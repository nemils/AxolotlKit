//
//  TSAxolotlRatchet.m
//  AxolotlKit
//
//  Created by Frederic Jacobs on 1/12/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.
//

#import "SessionCipher.h"

#import <25519/Curve25519.h>
#import <25519/Ed25519.h>

#import "NSData+keyVersionByte.h"

#import "AxolotlExceptions.h"
#import "SessionBuilder.h"
#import "SessionStore.h"
#import "AES-CBC.h"
#import "AxolotlParameters.h"
#import "MessageKeys.h"
#import "SessionState.h"
#import "ChainKey.h"
#import "RootKey.h"
#import "WhisperMessage.h"

#import "SignedPreKeyStore.h"
#import "PreKeyStore.h"

#import <HKDFKit/HKDFKit.h>

#import "AxolotlKitLogging.h"

@interface SessionCipher ()

@property NSString* recipientId;
@property int deviceId;

@property (nonatomic, retain) id<SessionStore> sessionStore;
@property (nonatomic, retain) SessionBuilder   *sessionBuilder;
@property (nonatomic, retain) id<PreKeyStore>  prekeyStore;

@end


@implementation SessionCipher


- (instancetype)initWithAxolotlStore:(id<AxolotlStore>)sessionStore recipientId:(NSString*)recipientId deviceId:(int)deviceId{
    return [self initWithSessionStore:sessionStore
                          preKeyStore:sessionStore
                    signedPreKeyStore:sessionStore
                     identityKeyStore:sessionStore
                          recipientId:recipientId
                             deviceId:deviceId];
}

- (instancetype)initWithSessionStore:(id<SessionStore>)sessionStore
                         preKeyStore:(id<PreKeyStore>)preKeyStore
                   signedPreKeyStore:(id<SignedPreKeyStore>)signedPreKeyStore
                    identityKeyStore:(id<IdentityKeyStore>)identityKeyStore
                         recipientId:(NSString*)recipientId
                            deviceId:(int)deviceId{
    self = [super init];

    if (self){
        self.recipientId       = recipientId;
        self.deviceId          = deviceId;
        self.sessionStore      = sessionStore;
        self.sessionBuilder    = [[SessionBuilder alloc] initWithSessionStore:sessionStore
                                                              preKeyStore:preKeyStore
                                                        signedPreKeyStore:signedPreKeyStore
                                                         identityKeyStore:identityKeyStore
                                                              recipientId:recipientId
                                                                 deviceId:deviceId];
    }
    
    return self;
}

- (id<CipherMessage>)encryptMessage:(NSData*)paddedMessage{
    
    SessionRecord *sessionRecord = [self.sessionStore loadSession:self.recipientId deviceId:self.deviceId];
    SessionState  *session       = sessionRecord.sessionState;
    ChainKey *chainKey           = session.senderChainKey;
    MessageKeys *messageKeys     = chainKey.messageKeys;
    NSData *senderRatchetKey     = session.senderRatchetKey;
    int previousCounter          = session.previousCounter;
    int sessionVersion           = session.version;
    

    NSData *ciphertextBody = [AES_CBC encryptCBCMode:paddedMessage withKey:messageKeys.cipherKey withIV:messageKeys.iv];

    AXOLog(@"[AXO][MESSAGE COUNTERS][NO VALID SESSIONS] Will create a whisper message for\n local identity: %@;\n remote identity: %@;\n senderChainKey index: %i;\n senderChainKey: %@;\n messageKeys index: %i;\n senderRathetKey: %@;\n previousCounter: %i",
           session.localIdentityKey,
           session.remoteIdentityKey,
           chainKey.index,
           chainKey.key,
           messageKeys.index,
           senderRatchetKey,
           previousCounter);
    
    id<CipherMessage> cipherMessage = [[WhisperMessage alloc] initWithVersion:sessionVersion
                                                                       macKey:messageKeys.macKey
                                                             senderRatchetKey:senderRatchetKey.prependKeyType
                                                                      counter:chainKey.index
                                                              previousCounter:previousCounter
                                                                   cipherText:ciphertextBody
                                                            senderIdentityKey:session.localIdentityKey.prependKeyType
                                                          receiverIdentityKey:session.remoteIdentityKey.prependKeyType];
    
    if ([session hasUnacknowledgedPreKeyMessage]){
        PendingPreKey *items = [session unacknowledgedPreKeyMessageItems];
        int localRegistrationId = [session localRegistrationId];
        
        cipherMessage = [[PreKeyWhisperMessage alloc] initWithWhisperMessage:cipherMessage
                                                              registrationId:localRegistrationId
                                                                    prekeyId:items.preKeyId
                                                              signedPrekeyId:items.signedPreKeyId
                                                                     baseKey:items.baseKey.prependKeyType
                                                                 identityKey:session.localIdentityKey.prependKeyType];
    }
    
    [session setSenderChainKey:[chainKey nextChainKey]];
    [self.sessionStore storeSession:self.recipientId deviceId:self.deviceId session:sessionRecord];
    
    return cipherMessage;
}

- (NSData*)decrypt:(id<CipherMessage>)whisperMessage{
    if ([whisperMessage isKindOfClass:[PreKeyWhisperMessage class]]) {
        return [self decryptPreKeyWhisperMessage:(PreKeyWhisperMessage*)whisperMessage];
    } else{
        return [self decryptWhisperMessage:whisperMessage];
    }
}

- (NSData*)decryptPreKeyWhisperMessage:(PreKeyWhisperMessage*)preKeyWhisperMessage{
    SessionRecord *sessionRecord = [self.sessionStore loadSession:self.recipientId deviceId:self.deviceId];
    int unsignedPreKeyId         = [self.sessionBuilder processPrekeyWhisperMessage:preKeyWhisperMessage withSession:sessionRecord deviceId:self.deviceId];
    NSData *plaintext            = [self decryptWithSessionRecord:sessionRecord whisperMessage:preKeyWhisperMessage.message];
    
    [self.sessionStore storeSession:self.recipientId deviceId:self.deviceId session:sessionRecord];
    
    if (unsignedPreKeyId >= 0) {
        [self.prekeyStore removePreKey:unsignedPreKeyId];
    }
    
    return plaintext;
}

- (NSData*)decryptWhisperMessage:(WhisperMessage*)message{
    if (![self.sessionStore containsSession:self.recipientId deviceId:self.deviceId]) {
        @throw [NSException exceptionWithName:NoSessionException reason:[NSString stringWithFormat:@"No session for: %@, %d", self.recipientId, self.deviceId] userInfo:nil];
    }
    
    SessionRecord  *sessionRecord  = [self.sessionStore loadSession:self.recipientId deviceId:self.deviceId];
    NSData         *plaintext      = [self decryptWithSessionRecord:sessionRecord whisperMessage:message];
    
    [self.sessionStore storeSession:self.recipientId deviceId:self.deviceId session:sessionRecord];
    
    return plaintext;
}


-(NSData*)decryptWithSessionRecord:(SessionRecord*)sessionRecord whisperMessage:(WhisperMessage*)message{
    SessionState            *sessionState = [sessionRecord sessionState];
    NSMutableArray        *previousStates = [sessionRecord previousSessionStates];
    NSMutableArray            *exceptions = [NSMutableArray array];
    
    @try {
        /*
         Creating a copy of a SessionState because `decryptWithSessionState:whisperMessage:` is mutating this object.
         In cases when decription fails we want to revert those changes. As there is not API to revert we are applying 
         SessionState to sessionRecord only if decryption succeeds.
         Situation like this can happen in case of arrival of out-of-order message. If that message "belongs" to one of
         previous session states, not reverting changes in current state will cause InvalidSession next time message will
         be sent using this session.
         */
        SessionState *sessionStateCopy = [sessionState copy];
        NSData * decryptedData = [self decryptWithSessionState:sessionStateCopy whisperMessage:message];
        [sessionRecord replaceSessionState:sessionState withSessionState:sessionStateCopy];
        return decryptedData;
    }
    @catch (NSException *exception) {
        if ([exception.name isEqualToString:InvalidMessageException]) {
            [exceptions addObject:exception];
        } else {
            @throw exception;
        }
    }
    
    for (SessionState *previousState in [previousStates copy]) {
        @try {
            // Creating a copy of a SessionState fot the same reason as above.
            SessionState *previousStateCopy = [previousState copy];
            NSData * decryptedData = [self decryptWithSessionState:previousStateCopy whisperMessage:message];
            [sessionRecord replaceSessionState:previousState withSessionState:previousStateCopy];
            return decryptedData;
        }
        @catch (NSException *exception) {
            [exceptions addObject:exception];
        }
    }
    
    @throw [NSException exceptionWithName:InvalidMessageException reason:@"No valid sessions" userInfo:@{@"Exceptions":exceptions}];
}

-(NSData*)decryptWithSessionState:(SessionState*)sessionState whisperMessage:(WhisperMessage*)message{
    if (![sessionState hasSenderChain]) {
        @throw [NSException exceptionWithName:InvalidMessageException reason:@"Uninitialized session!" userInfo:nil];
    }
    
    if (message.version != sessionState.version) {
        @throw [NSException exceptionWithName:InvalidMessageException reason:[NSString stringWithFormat:@"Got message version %d but was expecting %d", message.version, sessionState.version] userInfo:nil];
    }

    int messageVersion       = message.version;
    NSData *theirEphemeral   = message.senderRatchetKey.removeKeyType;
    int counter              = message.counter;
    ChainKey *chainKey       = [self getOrCreateChainKeys:sessionState theirEphemeral:theirEphemeral];
    MessageKeys *messageKeys = [self getOrCreateMessageKeysForSession:sessionState theirEphemeral:theirEphemeral chainKey:chainKey counter:counter];
    
    AXOLog(@"[AXO][NO VALID SESSIONS] Will verify mac for %@", [message isKindOfClass:[PreKeyWhisperMessage class]] ? @"PreKeyWhisperMessage" : @"WhisperMessage");
    
    
    AXOLog(@"[AXO][NO VALID SESSIONS] Will verify mac for\n local idenity: %@;\n remote identity: %@;\n chainKey index: %i;\n chainKey: %@;\n messageKeys index: %i;\n senderRathetKey: %@;\n counter: %i",
           sessionState.localIdentityKey,
           sessionState.remoteIdentityKey,
           chainKey.index,
           chainKey.key,
           messageKeys.index,
           theirEphemeral,
           counter);
    
    @try {
        [message verifyMacWithVersion:messageVersion senderIdentityKey:sessionState.remoteIdentityKey receiverIdentityKey:sessionState.localIdentityKey macKey:messageKeys.macKey];
    }
    @catch (NSException *exception) {
        
        if ([exception.reason isEqualToString:@"Bad Mac!"]) {
            @try {
                NSData *plaintext = [AES_CBC decryptCBCMode:message.cipherText withKey:messageKeys.cipherKey withIV:messageKeys.iv];
                AXOLog(@"[AXO][NO VALID SESSIONS] Succeeded in message decryption after getting bad mac! Decrypted message: %@", plaintext);
            }
            @catch (NSException *exception) {
                AXOLog(@"[AXO][NO VALID SESSIONS] Failed to decrypt message using messageKeys after getting bad mac.");
            }
        }
        
        @throw exception;
    }
    
    
    NSData *plaintext = [AES_CBC decryptCBCMode:message.cipherText withKey:messageKeys.cipherKey withIV:messageKeys.iv];
    
    [sessionState clearUnacknowledgedPreKeyMessage];
    
    return plaintext;
}

- (ChainKey*)getOrCreateChainKeys:(SessionState*)sessionState theirEphemeral:(NSData*)theirEphemeral{
    @try {
        if ([sessionState hasReceiverChain:theirEphemeral]) {
            AXOLog(@"[AXO][NO VALID SESSIONS] Retrieving reciever chain key for sender ratchet key %@", theirEphemeral);
            return [sessionState receiverChainKey:theirEphemeral];
        } else{
            RootKey *rootKey = [sessionState rootKey];
            ECKeyPair *ourEphemeral = [sessionState senderRatchetKeyPair];
            RKCK *receiverChain = [rootKey createChainWithTheirEphemeral:theirEphemeral ourEphemeral:ourEphemeral];
            ECKeyPair *ourNewEphemeral = [Curve25519 generateKeyPair];
            RKCK *senderChain = [receiverChain.rootKey createChainWithTheirEphemeral:theirEphemeral ourEphemeral:ourNewEphemeral];
            
            AXOLog(@"[AXO][NO VALID SESSIONS] Creating receiver chain key for\n sender ratchet key %@;\n root key: %@,\n receiver rathet key: %@;\n created receiver chain key: %@;\n creted receiver chain key index: %i;\n new receiver rathetKey: %@;\n new sender chain key %@;\n new sender chain key index: %i",
                   theirEphemeral,
                   rootKey.keyData,
                   ourEphemeral.publicKey,
                   receiverChain.chainKey.key,
                   receiverChain.chainKey.index,
                   ourNewEphemeral.publicKey,
                   senderChain.chainKey.key,
                   senderChain.chainKey.index);
            
            [sessionState setRootKey:senderChain.rootKey];
            [sessionState addReceiverChain:theirEphemeral chainKey:receiverChain.chainKey];
            [sessionState setPreviousCounter:MAX(sessionState.senderChainKey.index-1 , 0)];
            [sessionState setSenderChain:ourNewEphemeral chainKey:senderChain.chainKey];
            
            return receiverChain.chainKey;
        }
    }
    @catch (NSException *exception) {
        @throw [NSException exceptionWithName:InvalidMessageException reason:@"Chainkeys couldn't be derived" userInfo:nil];
    }
}

- (MessageKeys*)getOrCreateMessageKeysForSession:(SessionState*)sessionState theirEphemeral:(NSData*)theirEphemeral chainKey:(ChainKey*)chainKey counter:(int)counter{
    
    if (chainKey.index > counter) {
        if ([sessionState hasMessageKeys:theirEphemeral counter:counter]) {
            AXOLog(@"[AXO][MESSAGE COUNTERS] Removing message keys with counter %i", counter);
            return [sessionState removeMessageKeys:theirEphemeral counter:counter];
        }
        else{
            AXOLog(@"[AXO][MESSAGE COUNTERS] No message keys with counter %i. 'Received message with old counter exception will be thrown'", counter);
            @throw [NSException exceptionWithName:DuplicateMessageException reason:@"Received message with old counter!" userInfo:@{}];
        }
    }
    
    if (chainKey.index - counter > 2000) {
        @throw [NSException exceptionWithName:@"Over 500 messages into the future!" reason:@"" userInfo:@{}];
    }
    
    while (chainKey.index < counter) {
        MessageKeys *messageKeys = [chainKey messageKeys];
        [sessionState setMessageKeys:theirEphemeral messageKeys:messageKeys];
        chainKey = chainKey.nextChainKey;
    }
    
    AXOLog(@"[AXO][MESSAGE COUNTERS] Created message keys with counter %i", counter);
    [sessionState setReceiverChainKey:theirEphemeral chainKey:[chainKey nextChainKey]];
    return [chainKey messageKeys];
}

/**
 *  The current version data. First 4 bits are the current version and the last 4 ones are the lowest version we support.
 *
 *  @return Current version data
 */

+ (NSData*)currentProtocolVersion{
    NSUInteger index = 0b00100010;
    NSData *versionByte = [NSData dataWithBytes:&index length:1];
    return versionByte;
}


- (int)remoteRegistrationId{
    SessionRecord *record = [self.sessionStore loadSession:self.recipientId deviceId:_deviceId];
    
    if (!record) {
        @throw [NSException exceptionWithName:NoSessionException reason:@"Trying to get registration Id of a non-existing session." userInfo:nil];
    }
    
    return record.sessionState.remoteRegistrationId;
}

- (int)sessionVersion{
    SessionRecord *record = [self.sessionStore loadSession:self.recipientId deviceId:_deviceId];
    
    if (!record) {
        @throw [NSException exceptionWithName:NoSessionException reason:@"Trying to get the version of a non-existing session." userInfo:nil];
    }
    
    return record.sessionState.version;
}

@end
