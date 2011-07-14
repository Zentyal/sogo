/* MAPIStoreContext.m - this file is part of SOGo
 *
 * Copyright (C) 2010 Inverse inc.
 *
 * Author: Wolfgang Sourdeau <wsourdeau@inverse.ca>
 *
 * This file is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3, or (at your option)
 * any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */

#import <Foundation/NSDictionary.h>
#import <Foundation/NSNull.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSThread.h>

#import <NGObjWeb/WOContext.h>
#import <NGObjWeb/WOContext+SoObjects.h>

#import <NGExtensions/NSObject+Logs.h>

#import <SOGo/SOGoUser.h>

#import "SOGoMAPIFSFolder.h"
#import "SOGoMAPIFSMessage.h"

#import "MAPIApplication.h"
#import "MAPIStoreAttachment.h"
// #import "MAPIStoreAttachmentTable.h"
#import "MAPIStoreAuthenticator.h"
#import "MAPIStoreFolder.h"
#import "MAPIStoreFolderTable.h"
#import "MAPIStoreMapping.h"
#import "MAPIStoreMessage.h"
#import "MAPIStoreMessageTable.h"
#import "MAPIStoreFAIMessage.h"
#import "MAPIStoreFAIMessageTable.h"
#import "MAPIStoreTypes.h"
#import "NSArray+MAPIStore.h"
#import "NSObject+MAPIStore.h"
#import "NSString+MAPIStore.h"

#import "MAPIStoreContext.h"

#undef DEBUG
#include <stdbool.h>
#include <gen_ndr/exchange.h>
#include <libmapiproxy.h>
#include <mapistore/mapistore.h>
#include <mapistore/mapistore_errors.h>
#include <mapistore/mapistore_nameid.h>
#include <talloc.h>

/* TODO: homogenize method names and order of parameters */

@implementation MAPIStoreContext : NSObject

/* sogo://username:password@{contacts,calendar,tasks,journal,notes,mail}/dossier/id */

static Class NSDataK, NSStringK, MAPIStoreFAIMessageK;

static NSMutableDictionary *contextClassMapping;
static NSMutableDictionary *userMAPIStoreMapping;

+ (void) initialize
{
  NSArray *classes;
  Class currentClass;
  NSUInteger count, max;
  NSString *moduleName;

  NSDataK = [NSData class];
  NSStringK = [NSString class];
  MAPIStoreFAIMessageK = [MAPIStoreFAIMessage class];

  contextClassMapping = [NSMutableDictionary new];
  classes = GSObjCAllSubclassesOfClass (self);
  max = [classes count];
  for (count = 0; count < max; count++)
    {
      currentClass = [classes objectAtIndex: count];
      moduleName = [currentClass MAPIModuleName];
      if (moduleName)
	{
	  [contextClassMapping setObject: currentClass
			       forKey: moduleName];
	  NSLog (@"  registered class '%@' as handler of '%@' contexts",
		 NSStringFromClass (currentClass), moduleName);
	}
    }

  userMAPIStoreMapping = [NSMutableDictionary new];
}

static inline MAPIStoreContext *
_prepareContextClass (Class contextClass,
                      struct mapistore_connection_info *connInfo, NSURL *url)
{
  static NSMutableDictionary *registration = nil;
  MAPIStoreContext *context;
  MAPIStoreAuthenticator *authenticator;

  if (!registration)
    registration = [NSMutableDictionary new];

  if (![registration objectForKey: contextClass])
    [registration setObject: [NSNull null]
                  forKey: contextClass];

  context = [[contextClass alloc] initFromURL: url
                           withConnectionInfo: connInfo];
  [context autorelease];

  authenticator = [MAPIStoreAuthenticator new];
  [authenticator setUsername: [url user]];
  [authenticator setPassword: [url password]];
  [context setAuthenticator: authenticator];
  [authenticator release];

  [context setupRequest];
  [context setupBaseFolder: url];
  [context tearDownRequest];

  return context;
}

+ (int) openContext: (MAPIStoreContext **) contextPtr
            withURI: (const char *) newUri
  andConnectionInfo: (struct mapistore_connection_info *) newConnInfo
{
  MAPIStoreContext *context;
  Class contextClass;
  NSString *module, *completeURLString, *urlString;
  NSURL *baseURL;
  int rc = MAPISTORE_ERR_NOT_FOUND;

  NSLog (@"METHOD '%s' (%d) -- uri: '%s'", __FUNCTION__, __LINE__, newUri);

  context = nil;

  urlString = [NSString stringWithUTF8String: newUri];
  if (urlString)
    {
      completeURLString = [@"sogo://" stringByAppendingString: urlString];
      if (![completeURLString hasSuffix: @"/"])
	completeURLString = [completeURLString stringByAppendingString: @"/"];
      baseURL = [NSURL URLWithString: [completeURLString stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding]];
      if (baseURL)
        {
          module = [baseURL host];
          if (module)
            {
              contextClass = [contextClassMapping objectForKey: module];
              if (contextClass)
                {
                  context = _prepareContextClass (contextClass,
                                                  newConnInfo,
                                                  baseURL);
                  if (context)
                    {
                      *contextPtr = context;
                      rc = MAPISTORE_SUCCESS;
                    }
                }
              else
                NSLog (@"ERROR: unrecognized module name '%@'", module);
            }
        }
      else
        NSLog (@"ERROR: url could not be parsed");
    }
  else
    NSLog (@"ERROR: url is an invalid UTF-8 string");

  return rc;
}

- (id) init
{
  if ((self = [super init]))
    {
      woContext = [WOContext contextWithRequest: nil];
      [woContext retain];
      baseFolder = nil;
      contextUrl = nil;
    }

  return self;
}

- (id)   initFromURL: (NSURL *) newUrl
  withConnectionInfo: (struct mapistore_connection_info *) newConnInfo
{
  NSString *username;

  if ((self = [self init]))
    {
      ASSIGN (contextUrl, newUrl);

      username = [NSString stringWithUTF8String: newConnInfo->username];
      mapping = [userMAPIStoreMapping objectForKey: username];
      if (!mapping)
        {
          [self logWithFormat: @"generating mapping of ids for user '%@'",
                username];
          mapping = [MAPIStoreMapping mappingWithIndexing: newConnInfo->indexing];
          [userMAPIStoreMapping setObject: mapping forKey: username];
        }
   
      mstoreCtx = newConnInfo->mstore_ctx;
      connInfo = newConnInfo;
    }

  return self;
}

- (void) dealloc
{
  [baseFolder release];
  [woContext release];
  [authenticator release];

  [contextUrl release];

  [super dealloc];
}

- (WOContext *) woContext
{
  return woContext;
}

- (MAPIStoreMapping *) mapping
{
  return mapping;
}

- (void) setAuthenticator: (MAPIStoreAuthenticator *) newAuthenticator
{
  ASSIGN (authenticator, newAuthenticator);
}

- (MAPIStoreAuthenticator *) authenticator
{
  return authenticator;
}

- (NSURL *) url
{
  return contextUrl;
}

- (struct mapistore_connection_info *) connectionInfo
{
  return connInfo;
}

- (void) setupRequest
{
  NSMutableDictionary *info;

  [MAPIApp setMAPIStoreContext: self];
  info = [[NSThread currentThread] threadDictionary];
  [info setObject: woContext forKey: @"WOContext"];
}

- (void) tearDownRequest
{
  NSMutableDictionary *info;

  info = [[NSThread currentThread] threadDictionary];
  [info removeObjectForKey: @"WOContext"];
  [MAPIApp setMAPIStoreContext: nil];
}

// - (void) logRestriction: (struct mapi_SRestriction *) res
// 	      withState: (MAPIRestrictionState) state
// {
//   NSString *resStr;

//   resStr = MAPIStringForRestriction (res);

//   [self logWithFormat: @"%@  -->  %@", resStr, MAPIStringForRestrictionState (state)];
// }

- (int) getPath: (char **) path
         ofFMID: (uint64_t) fmid
       inMemCtx: (TALLOC_CTX *) memCtx
{
  int rc;
  NSString *objectURL, *url;
  // TDB_DATA key, dbuf;

  url = [contextUrl absoluteString];
  objectURL = [mapping urlFromID: fmid];
  if (objectURL)
    {
      if ([objectURL hasPrefix: url])
        {
          *path = [[objectURL substringFromIndex: 7]
		    asUnicodeInMemCtx: memCtx];
	  [self logWithFormat: @"found path '%s' for fmid %.16x",
		*path, fmid];
          rc = MAPI_E_SUCCESS;
        }
      else
        {
	  [self logWithFormat: @"context (%@, %@) does not contain"
		@" found fmid: 0x%.16x",
		objectURL, url, fmid];
          *path = NULL;
          rc = MAPI_E_NOT_FOUND;
        }
    }
  else
    {
      [self errorWithFormat: @"%s: you should *never* get here", __PRETTY_FUNCTION__];
      // /* attempt to populate our mapping dict with data from indexing.tdb */
      // key.dptr = (unsigned char *) talloc_asprintf (memCtx, "0x%.16llx",
      //                                               (long long unsigned int )fmid);
      // key.dsize = strlen ((const char *) key.dptr);

      // dbuf = tdb_fetch (memCtx->indexing_list->index_ctx->tdb, key);
      // talloc_free (key.dptr);
      // uri = talloc_strndup (memCtx, (const char *)dbuf.dptr, dbuf.dsize);
      *path = NULL;
      rc = MAPI_E_NOT_FOUND;
    }

  return rc;
}

- (int) getRootFolder: (MAPIStoreFolder **) folderPtr
              withFID: (uint64_t) newFid
{
  if (![mapping urlFromID: newFid])
    [mapping registerURL: [contextUrl absoluteString]
                  withID: newFid];
  *folderPtr = baseFolder;

  return (baseFolder) ? MAPISTORE_SUCCESS: MAPISTORE_ERROR;
}

/* utils */

- (NSString *) extractChildNameFromURL: (NSString *) objectURL
			andFolderURLAt: (NSString **) folderURL;
{
  NSString *childKey;
  NSRange lastSlash;
  NSUInteger slashPtr;

  if ([objectURL hasSuffix: @"/"])
    objectURL = [objectURL substringToIndex: [objectURL length] - 2];
  lastSlash = [objectURL rangeOfString: @"/"
			       options: NSBackwardsSearch];
  if (lastSlash.location != NSNotFound)
    {
      slashPtr = NSMaxRange (lastSlash);
      childKey = [objectURL substringFromIndex: slashPtr];
      if ([childKey length] == 0)
	childKey = nil;
      if (folderURL)
	*folderURL = [objectURL substringToIndex: slashPtr];
    }
  else
    childKey = nil;

  return childKey;
}

- (uint64_t) idForObjectWithKey: (NSString *) key
                    inFolderURL: (NSString *) folderURL
{
  NSString *childURL;
  uint64_t mappingId;
  uint32_t contextId;
  void *rootObject;

  if (key)
    childURL = [NSString stringWithFormat: @"%@%@", folderURL, key];
  else
    childURL = folderURL;
  mappingId = [mapping idFromURL: childURL];
  if (mappingId == NSNotFound)
    {
      [self warnWithFormat: @"no id exist yet, requesting one..."];
      openchangedb_get_new_folderID (connInfo->oc_ctx, &mappingId);
      [mapping registerURL: childURL withID: mappingId];
      contextId = 0;
      mapistore_search_context_by_uri (mstoreCtx, [folderURL UTF8String] + 7,
                                       &contextId, &rootObject);
      mapistore_indexing_record_add_mid (mstoreCtx, contextId, mappingId);
    }

  return mappingId;
}

/* subclasses */

+ (NSString *) MAPIModuleName
{
  [self subclassResponsibility: _cmd];

  return nil;
}

- (void) setupBaseFolder: (NSURL *) newURL
{
  [self subclassResponsibility: _cmd];
}

@end
