#import "SSEMIDIController.h"

#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>

#import "SSEMainWindowController.h"


@interface SSEMIDIController (Private)

- (void)_midiSetupDidChange:(NSNotification *)notification;

- (void)_endpointAppeared:(NSNotification *)notification;
- (void)_outputStreamEndpointDisappeared:(NSNotification *)notification;

- (void)_selectFirstAvailableDestination;

- (void)_startListening;
- (void)_readingSysEx:(NSNotification *)notification;
- (void)_mainThreadTakeMIDIMessages:(NSArray *)messagesToTake;

- (void)_sendNextSysExMessage;
- (void)_willStartSendingSysEx:(NSNotification *)notification;
- (void)_doneSendingSysEx:(NSNotification *)notification;

@end


@implementation SSEMIDIController

- (id)init
{
    NSNotificationCenter *center;
    NSArray *sources;
    unsigned int sourceIndex;

    if (!(self = [super init]))
        return nil;

    center = [NSNotificationCenter defaultCenter];

    inputStream = [[SMPortInputStream alloc] init];
    [center addObserver:self selector:@selector(_readingSysEx:) name:SMInputStreamReadingSysExNotification object:inputStream];
    [center addObserver:self selector:@selector(_readingSysEx:) name:SMInputStreamDoneReadingSysExNotification object:inputStream];
    [inputStream setMessageDestination:self];
    sources = [SMSourceEndpoint sourceEndpoints];
    sourceIndex = [sources count];
    while (sourceIndex--)
        [inputStream addEndpoint:[sources objectAtIndex:sourceIndex]];

    outputStream = [[SMPortOrVirtualOutputStream alloc] init];
    [center addObserver:self selector:@selector(_outputStreamEndpointDisappeared:) name:SMPortOrVirtualStreamEndpointDisappearedNotification object:outputStream];
    [center addObserver:self selector:@selector(_willStartSendingSysEx:) name:SMPortOutputStreamWillStartSysExSendNotification object:outputStream];
    [center addObserver:self selector:@selector(_doneSendingSysEx:) name:SMPortOutputStreamFinishedSysExSendNotification object:outputStream];
    [outputStream setIgnoresTimeStamps:YES];
    [outputStream setSendsSysExAsynchronously:YES];
    [outputStream setVirtualDisplayName:NSLocalizedStringFromTableInBundle(@"Act as a source for other programs", @"SysExLibrarian", [self bundle], "title of popup menu item for virtual source")];
    [outputStream setVirtualEndpointName:@"SysEx Librarian"];	// TODO get this from somewhere

    [center addObserver:self selector:@selector(_endpointAppeared:) name:SMEndpointAppearedNotification object:nil];
    
    listenToMIDISetupChanges = YES;

    messages = [[NSMutableArray alloc] init];    
    messageBytesRead = 0;
    totalBytesRead = 0;
    
    listeningToMessages = NO;
    listenToMultipleMessages = NO;

    pauseTimeBetweenMessages = 0.150;	// 150 ms
    sendProgressLock = [[NSLock alloc] init];
    
    [center addObserver:self selector:@selector(_midiSetupDidChange:) name:SMClientSetupChangedNotification object:[SMClient sharedClient]];

    // TODO should get selected dest from preferences
    [self _selectFirstAvailableDestination];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [inputStream release];
    inputStream = nil;
    [outputStream release];
    outputStream = nil;
    [messages release];
    messages = nil;
    [sendProgressLock release];
    sendProgressLock = nil;
    [sendNextMessageEvent release];
    sendNextMessageEvent = nil;

    [super dealloc];
}

//
// API for SSEMainWindowController
//

- (NSArray *)destinationDescriptions;
{
    return [outputStream endpointDescriptions];
}

- (NSDictionary *)destinationDescription;
{
    return [outputStream endpointDescription];
}

- (void)setDestinationDescription:(NSDictionary *)description;
{
    NSDictionary *oldDescription;
    BOOL savedListenFlag;

    oldDescription = [self destinationDescription];
    if (oldDescription == description || [oldDescription isEqual:description])
        return;

    savedListenFlag = listenToMIDISetupChanges;
    listenToMIDISetupChanges = NO;

    [outputStream setEndpointDescription:description];
    // TODO we don't have an undo manager yet
    //    [[[self undoManager] prepareWithInvocationTarget:self] setSourceDescription:oldDescription];
    //    [[self undoManager] setActionName:NSLocalizedStringFromTableInBundle(@"Change Source", @"SysExLibrarian", [self bundle], "change source undo action")];

    listenToMIDISetupChanges = savedListenFlag;

    [windowController synchronizeDestinations];
}

- (NSTimeInterval)pauseTimeBetweenMessages;
{
    return pauseTimeBetweenMessages;
}

- (void)setPauseTimeBetweenMessages:(NSTimeInterval)value;
{
    pauseTimeBetweenMessages = value;
}

- (NSArray *)messages;
{
    return messages;
}

- (void)setMessages:(NSArray *)value;
{
    // Shouldn't do this while listening for messages or playing messages
    OBASSERT(listeningToMessages == NO);
    OBASSERT(nonretainedCurrentSendRequest == nil);
    
    if (value != messages) {
        [messages release];
        messages = [[NSMutableArray alloc] initWithArray:value];
    }
}

//
// Listening to sysex messages
//

- (void)listenForOneMessage;
{
    listenToMultipleMessages = NO;
    [self _startListening];
}

- (void)listenForMultipleMessages;
{
    listenToMultipleMessages = YES;
    [self _startListening];
}

- (void)cancelMessageListen;
{
    listeningToMessages = NO;
    [inputStream cancelReceivingSysExMessage];

    [messages removeAllObjects];
    messageBytesRead = 0;
    totalBytesRead = 0;
}

- (void)doneWithMultipleMessageListen;
{
    listeningToMessages = NO;
    [inputStream cancelReceivingSysExMessage];
}

- (void)getMessageCount:(unsigned int *)messageCountPtr bytesRead:(unsigned int *)bytesReadPtr totalBytesRead:(unsigned int *)totalBytesReadPtr;
{
    // There is no need to put a lock around these things, assuming that we are in the main thread.
    // messageBytesRead gets changed in a different thread, but it gets changed atomically.
    // messages and totalBytesRead are only modified in the main thread.
    OBASSERT([NSThread inMainThread])    

    if (messageCountPtr)
        *messageCountPtr = [messages count];
    if (bytesReadPtr)
        *bytesReadPtr = messageBytesRead;
    if (totalBytesReadPtr)
        *totalBytesReadPtr = totalBytesRead;
}

//
// Sending sysex messages
//

- (void)sendMessages;
{
    unsigned int messageIndex, messageCount;

    OBASSERT([NSThread inMainThread]);

    if (!messages || (messageCount = [messages count]) == 0)
        return;

    if (![outputStream canSendSysExAsynchronously]) {
        // Just dump all the messages out at once
        [outputStream takeMIDIMessages:messages];
        return;
    }

    nonretainedCurrentSendRequest = nil;
    sendingMessageCount = messageCount;
    sendingMessageIndex = 0;
    bytesToSend = 0;
    bytesSent = 0;
    sendCancelled = NO;

    for (messageIndex = 0; messageIndex < messageCount; messageIndex++)
        bytesToSend += [[messages objectAtIndex:messageIndex] fullMessageDataLength];

    [self _sendNextSysExMessage];

    [windowController showSysExSendStatus];
}

- (void)cancelSendingMessages;
{
    OBASSERT([NSThread inMainThread]);

    if (sendNextMessageEvent && [[OFScheduler mainScheduler] abortEvent:sendNextMessageEvent]) {
        [windowController hideSysExSendStatusWithSuccess:NO];
    } else {
        sendCancelled = YES;
        [outputStream cancelPendingSysExSendRequests];
        // We will get notified when the current send request is finished
    }
}

- (void)getMessageCount:(unsigned int *)messageCountPtr messageIndex:(unsigned int *)messageIndexPtr bytesToSend:(unsigned int *)bytesToSendPtr bytesSent:(unsigned int *)bytesSentPtr;
{
    OBASSERT([NSThread inMainThread])

    [sendProgressLock lock];
    
    if (messageCountPtr)
        *messageCountPtr = sendingMessageCount;
    if (messageIndexPtr)
        *messageIndexPtr = sendingMessageIndex;
    if (bytesToSendPtr)
        *bytesToSendPtr = bytesToSend;
    if (bytesSentPtr) {
        *bytesSentPtr = bytesSent;
        if (nonretainedCurrentSendRequest)
            *bytesSentPtr += [nonretainedCurrentSendRequest bytesSent];
    }

    [sendProgressLock unlock];
}


//
// SMMessageDestination protocol
//

- (void)takeMIDIMessages:(NSArray *)messagesToTake;
{
    [self queueSelector:@selector(_mainThreadTakeMIDIMessages:) withObject:messagesToTake];
}

@end


@implementation SSEMIDIController (Private)

- (void)_midiSetupDidChange:(NSNotification *)notification;
{
    if (listenToMIDISetupChanges) {
        [windowController synchronizeDestinations];
    }
}

- (void)_endpointAppeared:(NSNotification *)notification;
{
    SMEndpoint *endpoint;

    endpoint = [notification object];
    if ([endpoint isKindOfClass:[SMSourceEndpoint class]])
        [inputStream addEndpoint:(SMSourceEndpoint *)endpoint];
}

- (void)_outputStreamEndpointDisappeared:(NSNotification *)notification;
{
    // TODO should print a message?

    // NOTE: We are handling a MIDI change notification right now. We might want to select a virtual destination
    // but an SMVirtualOutputStream can't be created in the middle of handling this notification, so do it later.
    [self performSelector:@selector(_selectFirstAvailableDestination) withObject:nil afterDelay:0];
}

- (void)_selectFirstAvailableDestination;
{
    NSArray *descriptions;

    descriptions = [outputStream endpointDescriptions];
    if ([descriptions count] > 0)
        [self setDestinationDescription:[descriptions objectAtIndex:0]];
}


//
// Listening to sysex messages
//

- (void)_startListening;
{
    OBASSERT(listeningToMessages == NO);
    
    [inputStream cancelReceivingSysExMessage];
        // In case a sysex message is currently being received

    [messages removeAllObjects];
    messageBytesRead = 0;
    totalBytesRead = 0;

    listeningToMessages = YES;
}

- (void)_readingSysEx:(NSNotification *)notification;
{
    // NOTE This is happening in the MIDI thread

    messageBytesRead = [[[notification userInfo] objectForKey:@"length"] unsignedIntValue];
    [windowController queueSelectorOnce:@selector(updateSysExReadIndicator)];
        // We want multiple updates to get coalesced, so only queue it once
}

- (void)_mainThreadTakeMIDIMessages:(NSArray *)messagesToTake;
{
    unsigned int messageCount, messageIndex;

    if (!listeningToMessages)
        return;

    messageCount = [messagesToTake count];
    for (messageIndex = 0; messageIndex < messageCount; messageIndex++) {
        SMMessage *message;

        message = [messagesToTake objectAtIndex:messageIndex];
        if ([message isKindOfClass:[SMSystemExclusiveMessage class]]) {
            [messages addObject:message];
            totalBytesRead += messageBytesRead;
            messageBytesRead = 0;

            [windowController updateSysExReadIndicator];
            if (listenToMultipleMessages == NO)  {
                listeningToMessages = NO;
                [windowController stopSysExReadIndicator];
                [windowController addReadMessagesToLibrary];
                break;
            }
        }
    }
}


//
// Sending sysex messages
//

- (void)_sendNextSysExMessage;
{
    [sendNextMessageEvent release];
    sendNextMessageEvent = nil;
    
    [outputStream takeMIDIMessages:[NSArray arrayWithObject:[messages objectAtIndex:sendingMessageIndex]]];
}

- (void)_willStartSendingSysEx:(NSNotification *)notification;
{
    OBASSERT(nonretainedCurrentSendRequest == nil);
    nonretainedCurrentSendRequest = [[notification userInfo] objectForKey:@"sendRequest"];
}

- (void)_doneSendingSysEx:(NSNotification *)notification;
{
    // NOTE This is happening in the MIDI thread, probably.
    // The request may or may not have finished successfully.
    SMSysExSendRequest *sendRequest;

    sendRequest = [[notification userInfo] objectForKey:@"sendRequest"];
    OBASSERT(sendRequest == nonretainedCurrentSendRequest);

    [sendProgressLock lock];

    bytesSent += [sendRequest bytesSent];
    sendingMessageIndex++;
    nonretainedCurrentSendRequest = nil;
    
    [sendProgressLock unlock];

    if (sendCancelled) {
        [windowController mainThreadPerformSelector:@selector(hideSysExSendStatusWithSuccess:) withBool:NO];
    } else if (sendingMessageIndex < sendingMessageCount && [sendRequest wereAllBytesSent]) {
        sendNextMessageEvent = [[[OFScheduler mainScheduler] scheduleSelector:@selector(_sendNextSysExMessage) onObject:self afterTime:pauseTimeBetweenMessages] retain];
    } else {
        [windowController mainThreadPerformSelector:@selector(hideSysExSendStatusWithSuccess:) withBool:[sendRequest wereAllBytesSent]];
    }
}

@end
