//
//  CDVAccountManager.h
//  Qvout
//
//  Created by alex on 16.04.15.
//  Copyright (c) 2015 alex. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^AccountManagerCompletionBlock)(BOOL success, NSDictionary *dataDictionary, NSError *error);
typedef void(^ContactsListCompletionBlock)(NSArray *contactsList);

@interface CDVAccountManager : NSObject

+ (CDVAccountManager *)sharedInstance;

/// Contacts - call for iOS version 9.0+
- (void)contactsFromContactListCompletionBlock:(ContactsListCompletionBlock)completionBlock;

/// Facebook
- (void)facebookUserWithCompletionBlock:(AccountManagerCompletionBlock)completionBlock;
- (void)facebookFriendsListFromSocialFrameworkWithCompletionBlock:(AccountManagerCompletionBlock)completionBlock;
- (void)facebookUserImages;

@end
