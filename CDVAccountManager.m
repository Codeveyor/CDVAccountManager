//
//  CDVAccountManager.m
//  Qvout
//
//  Created by alex on 16.04.15.
//  Copyright (c) 2015 alex. All rights reserved.
//

#import "CDVAccountManager.h"
#import "SynthesizeSingleton.h"

#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKLoginKit/FBSDKLoginKit.h>

@import Social;
@import Accounts;
@import Contacts;

#import "CDVMemberModel.h"

@interface CDVAccountManager ()

@property (nonatomic, strong) ACAccountStore *accountStore;
@property (nonatomic, strong) ACAccount *facebookAccount;

@property (nonatomic, strong) CNContactStore *contactStore;

@property (nonatomic, strong) CDVDatabaseManager *databaseManager;
@property (nonatomic, strong) CDVRequestManager *requestManager;

@end

static NSString * const kFacebookAppID = @"FacebookAppID";

@implementation CDVAccountManager
SYNTHESIZE_SINGLETON_FOR_CLASS(CDVAccountManager)

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _databaseManager = [CDVDatabaseManager sharedInstance];
        _requestManager = [CDVRequestManager sharedInstance];
    }
    
    return self;
}

#pragma mark - Contacts

- (void)contactsFromContactListCompletionBlock:(ContactsListCompletionBlock)completionBlock
{
    __weak typeof(self) weakSelf = self;
    [self checkAccessStatusCompletionHandler:^(BOOL accessGranted){
        
        CNContactFetchRequest *fetchRequest = [[CNContactFetchRequest alloc]initWithKeysToFetch:@[CNContactGivenNameKey, CNContactFamilyNameKey, CNContactImageDataKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey]];
        NSError *error = nil;
        NSMutableArray *contactsArray = [NSMutableArray array];

        [weakSelf.contactStore enumerateContactsWithFetchRequest:fetchRequest
                                                           error:&error
                                                      usingBlock:^(CNContact * _Nonnull contact, BOOL * _Nonnull stop) {
            
            CDVMemberModel *memberModelFromContact = [CDVMemberModel new];
            
            // Names
            memberModelFromContact.firstName = contact.givenName;
            memberModelFromContact.lastName = contact.familyName;
            
            // Avatar
            NSData *imgData = contact.imageData;
            if (imgData)
            {
                memberModelFromContact.avatarImage = [[CDVUtils sharedInstance]maskImage:[UIImage imageWithData:imgData]];
            }
        
            // Phone Number
            NSArray <CNLabeledValue<CNPhoneNumber *> *> *phoneNumbersArray = contact.phoneNumbers;
            if (phoneNumbersArray.count > 0)
            {
                CNLabeledValue<CNPhoneNumber *> *firstPhone = [phoneNumbersArray firstObject];
                memberModelFromContact.phoneNumber = firstPhone.value.stringValue;
            }
            
            // Email
            NSArray *emailsArray = contact.emailAddresses;
            if (emailsArray.count > 0)
            {
                CNLabeledValue *firstEmail = [emailsArray firstObject];
                memberModelFromContact.email = firstEmail.value;
            }
            
            // Network ID
            memberModelFromContact.networkID = kQvoutID;
            
            if (memberModelFromContact.firstName && (memberModelFromContact.email || memberModelFromContact.phoneNumber))
            {
                [contactsArray addObject:memberModelFromContact];
            }
        }];
        
        completionBlock([contactsArray copy]);
    }];
}

- (void)checkAccessStatusCompletionHandler:(void (^)(BOOL accessGranted))completionHandler
{
    self.contactStore = [CNContactStore new];
    CNAuthorizationStatus authorizationStatus = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
    switch (authorizationStatus)
    {
        case CNAuthorizationStatusAuthorized:
        {
            completionHandler(YES);
            break;
        }
        case CNAuthorizationStatusDenied:
        case CNAuthorizationStatusNotDetermined:
        {
            [self.contactStore requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError * _Nullable error) {
                
                completionHandler(granted);
            }];
            break;
        }
        case CNAuthorizationStatusRestricted:
        {
            NSLog(@"CNAuthorizationStatusRestricted");
            break;
        }
        default:
            completionHandler(NO);
            break;
    }
}

#pragma mark - Facebook Social Framework

- (void)facebookSocialUserWithCompletionBlock:(AccountManagerCompletionBlock)completionBlock
{
    ACAccountStore *accountStore = [ACAccountStore new];
    ACAccountType *facebookTypeAccount = [accountStore accountTypeWithAccountTypeIdentifier:ACAccountTypeIdentifierFacebook];
    NSDictionary *options = @{
                              ACFacebookAppIdKey:[[NSBundle mainBundle] objectForInfoDictionaryKey:kFacebookAppID],
                              ACFacebookPermissionsKey:@[@"email", @"public_profile"],
                              };
    
    [accountStore requestAccessToAccountsWithType:facebookTypeAccount options:options completion:^(BOOL granted, NSError *error) {
        
        if(granted)
        {
            ACAccount *facebookAccount = [[accountStore accountsWithAccountType:facebookTypeAccount]lastObject];
            SLRequest *meRequest = [SLRequest requestForServiceType:SLServiceTypeFacebook
                                                      requestMethod:SLRequestMethodGET
                                                                URL:[NSURL
                                                                     URLWithString:@"https://graph.facebook.com/me"] parameters:nil];
            meRequest.account = facebookAccount;
            
            __weak CDVAccountManager *weakSelf = self;
            [meRequest performRequestWithHandler:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
                
                if(!error)
                {
                    NSDictionary *responseDictionary = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
                    NSLog(@"%@", responseDictionary);
                    if(responseDictionary[kErrorPropertyName])
                    {
                        completionBlock(NO, nil, error);
                    }
                    else
                    {
                        // dictionary to post to backend
                        NSMutableDictionary *postUserDictionary = [NSMutableDictionary dictionary];
                        [postUserDictionary setValue:responseDictionary[kEmailURLPropertyName] forKey:kEmailURLPropertyName];
                        NSArray *namesArray = [responseDictionary[kNamePropertyName] componentsSeparatedByString:@" "];
                        if ([namesArray[0] length] > 0)
                        {
                            [postUserDictionary setValue:namesArray[0] forKey:kFirstNameURLPropertyName];
                        }
                        if (namesArray[1])
                        {
                            [postUserDictionary setValue:namesArray[1] forKey:kLastNameURLPropertyName];
                        }
                        [postUserDictionary setValue:[NSString stringWithFormat:@"%d", kFacebookID] forKey:kNetworkIDURLPropertyName];
                        [postUserDictionary setValue:responseDictionary[kLinkURLPropertyName] forKey:kNetworkReferenceURLPropertyName];
                        CDVSocialDB *social = [weakSelf.databaseManager socialNetworkForValue:kFacebookID];
                        [postUserDictionary setValue:social forKey:kSocialPropertyName];
                        
                        NSString *URLString = [NSString stringWithFormat:@"http://graph.facebook.com/%@/picture?type=square", responseDictionary[kIDURLPropertyName]];
                        
                        [weakSelf.requestManager getImageFromURLString:URLString successBlock:^(BOOL success, UIImage *image, NSError *error) {
                            
                            if (success)
                            {
                                [weakSelf.requestManager postUserFromSocialsDictionary:[postUserDictionary copy] image:image socialDictionary:responseDictionary successBlock:^(BOOL success, NSDictionary *dataDictionary, NSError *error) {
                                    
                                    if (success)
                                    {
                                        [weakSelf.databaseManager saveUserFromSocialRetreivedDictionary:dataDictionary socialDictionary:[postUserDictionary copy] avatarImage:image];
                                        completionBlock(YES, nil, nil);
                                    }
                                    else
                                    {
                                        completionBlock(NO, nil, error);
                                    }
                                }];
                            }
                            else
                            {
                                completionBlock(NO, nil, error);
                            }
                        }];
                    }
                }
                else
                {
                    completionBlock(NO, nil, error);
                }
            }];
        }
        else
        {
            completionBlock(NO, nil, error);
        }
    }];
}

- (void)facebookSocialFriendsListWithCompletionBlock:(AccountManagerCompletionBlock)completionBlock
{
    ACAccountStore *accountStore = [ACAccountStore new];
    ACAccountType *facebookTypeAccount = [accountStore accountTypeWithAccountTypeIdentifier:ACAccountTypeIdentifierFacebook];
    NSDictionary *options = @{
                              ACFacebookAppIdKey:[[NSBundle mainBundle] objectForInfoDictionaryKey:kFacebookAppID],
                              ACFacebookPermissionsKey:@[kEmailURLPropertyName, @"read_friendlists"],
                              ACFacebookAudienceKey:ACFacebookAudienceFriends
                              };
    
    [accountStore requestAccessToAccountsWithType:facebookTypeAccount options:options completion:^(BOOL granted, NSError *error) {
        
        if(granted)
        {
            ACAccount *facebookAccount = [[accountStore accountsWithAccountType:facebookTypeAccount]lastObject];
            
            SLRequest *meRequest = [SLRequest requestForServiceType:SLServiceTypeFacebook requestMethod:SLRequestMethodGET URL:[NSURL URLWithString:@"https://graph.facebook.com/me"] parameters:nil];
            meRequest.account = facebookAccount;
            SLRequest *friendsRequest = [SLRequest requestForServiceType:SLServiceTypeFacebook requestMethod:SLRequestMethodGET URL:[NSURL URLWithString:@"https://graph.facebook.com/me/friends"] parameters:@{@"fields":@"id, name, email, picture, first_name, last_name, gender, installed"}];
            friendsRequest.account = facebookAccount;
            
            [friendsRequest performRequestWithHandler:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
                
                if(!error)
                {
                    NSDictionary *responseDictionary = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
                    if(responseDictionary[kErrorPropertyName])
                    {
                        completionBlock(NO, responseDictionary, nil);
                    }
                    else
                    {
                        completionBlock(YES, responseDictionary, nil);
                    }
                }
                else
                {
                    completionBlock(NO, nil, error);
                }
            }];
        }
        else
        {
            completionBlock(NO, nil, error);
            NSLog(@"Facebook Social grant error:%@", error);
        }
    }];
}

//TODO: implement this method to work correctly(right permissions)
- (void)facebookUserImages
{
    ACAccountStore *accountStore = [ACAccountStore new];
    ACAccountType *facebookTypeAccount = [accountStore accountTypeWithAccountTypeIdentifier:ACAccountTypeIdentifierFacebook];
    NSDictionary *options = @{
                              ACFacebookAppIdKey:[[NSBundle mainBundle] objectForInfoDictionaryKey:kFacebookAppID],
                              ACFacebookPermissionsKey:@[kEmailURLPropertyName, @"read_friendlists", @"albums"],
                              ACFacebookAudienceKey:ACFacebookAudienceFriends
                              };
    
    [accountStore requestAccessToAccountsWithType:facebookTypeAccount options:options completion:^(BOOL granted, NSError *error) {
        
        if(granted)
        {
            ACAccount *facebookAccount = [[accountStore accountsWithAccountType:facebookTypeAccount]lastObject];
            
            SLRequest *meRequest = [SLRequest requestForServiceType:SLServiceTypeFacebook requestMethod:SLRequestMethodGET URL:[NSURL URLWithString:@"https://graph.facebook.com/me/albums"] parameters:nil];
            meRequest.account = facebookAccount;
            
            [meRequest performRequestWithHandler:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
                
                // implement completion block for handling all situations
                if(!error)
                {
                    NSDictionary *responseDictionary = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
                    if(responseDictionary[kErrorPropertyName])
                    {
                        NSLog(@"Facebook returned error: %@", responseDictionary[kErrorPropertyName]);
                    }
                    else
                    {
                        
                    }
                }
                else
                {
                    NSLog(@"FB Error:%@", error);
                }
            }];
        }
        else
        {
            NSLog(@"Facebook Social grant error:%@", error);
        }
    }];
}

#pragma mark - Facebook SDK

- (void)facebookSDKUserWithCompletionBlock:(AccountManagerCompletionBlock)completionBlock
{
    __weak typeof(self) weakSelf = self;
    [self requestPermissions:@[@"email", @"public_profile"]
             completionBlock:^(BOOL success, NSDictionary *dataDictionary, NSError *error) {
                 
                 if (!error)
                 {
                     [[[FBSDKGraphRequest alloc]initWithGraphPath:@"me"
                                                       parameters:@{@"fields":@"email, name, link, birthday"}]
                      startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id responseDictionary, NSError *graphRequestError) {
                          
                          if(!graphRequestError)
                          {
                              // dictionary to post to backend
                              NSMutableDictionary *postUserDictionary = [NSMutableDictionary dictionary];
                              [postUserDictionary setValue:responseDictionary[kEmailURLPropertyName]
                                                    forKey:kEmailURLPropertyName];
                              NSArray *namesArray = [responseDictionary[kNamePropertyName]
                                                     componentsSeparatedByString:@" "];
                              if ([namesArray[0] length] > 0)
                              {
                                  [postUserDictionary setValue:namesArray[0]
                                                        forKey:kFirstNameURLPropertyName];
                              }
                              if (namesArray[1])
                              {
                                  [postUserDictionary setValue:namesArray[1]
                                                        forKey:kLastNameURLPropertyName];
                              }
                              [postUserDictionary setValue:[NSString stringWithFormat:@"%d", kFacebookID]
                                                    forKey:kNetworkIDURLPropertyName];
                              [postUserDictionary setValue:responseDictionary[kLinkURLPropertyName]
                                                    forKey:kNetworkReferenceURLPropertyName];
                              QVTSocialDB *social = [weakSelf.databaseManager socialNetworkForValue:kFacebookID];
                              [postUserDictionary setValue:social
                                                    forKey:kSocialPropertyName];
                              
                              NSString *URLString = [NSString stringWithFormat:@"http://graph.facebook.com/%@/picture?type=square", responseDictionary[kIDURLPropertyName]];
                              
                              [weakSelf.requestManager getImageFromURLString:URLString
                                                                successBlock:^(BOOL success, UIImage *image, NSError *getImageError) {
                                                                    
                                                                    if (success)
                                                                    {
                                                                        [weakSelf.requestManager postUserFromSocialsDictionary:[postUserDictionary copy]
                                                                                                                         image:image
                                                                                                              socialDictionary:responseDictionary
                                                                                                                  successBlock:^(BOOL success, NSDictionary *dataDictionary, NSError *postUserError) {
                                                                                                                      
                                                                                                                      if (success)
                                                                                                                      {
                                                                                                                          [weakSelf.databaseManager saveUserFromSocialRetreivedDictionary:dataDictionary
                                                                                                                                                                         socialDictionary:[postUserDictionary copy]
                                                                                                                                                                              avatarImage:image];
                                                                                                                          completionBlock(YES, nil, nil);
                                                                                                                      }
                                                                                                                      else
                                                                                                                      {
                                                                                                                          completionBlock(NO, nil, postUserError);
                                                                                                                      }
                                                                                                                  }];
                                                                    }
                                                                    else
                                                                    {
                                                                        completionBlock(NO, nil, getImageError);
                                                                    }
                                                                }];
                          }
                          else
                          {
                              completionBlock(NO, nil, graphRequestError);
                          }
                      }];
                 }
                 else
                 {
                     completionBlock(NO, nil, error);
                 }
             }];
}

- (void)facebookSDKFriendsListWithCompletionBlock:(AccountManagerCompletionBlock)completionBlock
{
    [self requestPermissions:@[@"user_friends"]
             completionBlock:^(BOOL success, NSDictionary *dataDictionary, NSError *error) {
                 
                 if (!error)
                 {
                     [[[FBSDKGraphRequest alloc]initWithGraphPath:@"me/friends"
                                                       parameters:@{@"fields":@"email, name, picture"}]
                      startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id responseDictionary, NSError *graphRequestError) {
                          
                          if(!graphRequestError)
                          {
                              completionBlock(YES, responseDictionary, nil);
                          }
                          else
                          {
                              completionBlock(NO, nil, graphRequestError);
                          }
                      }];
                 }
                 else
                 {
                     completionBlock(NO, nil, error);
                 }
             }];
}

#pragma mark - Utils

- (void)requestPermissions:(NSArray *)permissionsArray
           completionBlock:(AccountManagerCompletionBlock)completionBlock
{
    FBSDKLoginManager *loginManager = [FBSDKLoginManager new];
    loginManager.loginBehavior = FBSDKLoginBehaviorSystemAccount;
    [loginManager logInWithReadPermissions:permissionsArray
                        fromViewController:nil
                                   handler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
                                       
                                       if (error)
                                       {
                                           completionBlock(NO, nil, error);
                                       }
                                       else if (result.isCancelled)
                                       {
                                           NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
                                           [userInfo setValue:@"FB auth was cancelled"
                                                       forKey:NSLocalizedDescriptionKey];
                                           [userInfo setValue:@"FB auth was cancelled"
                                                       forKey:NSLocalizedFailureReasonErrorKey];
                                           NSError *cancelledError = [[NSError alloc]initWithDomain:@"FB auth was cancelled"
                                                                                               code:kFacebookCancelledLogin
                                                                                           userInfo:userInfo];
                                           completionBlock(NO, nil, cancelledError);
                                       }
                                       else
                                       {
                                           completionBlock(YES, nil, error);
                                       }
                                   }];
    
}

@end
