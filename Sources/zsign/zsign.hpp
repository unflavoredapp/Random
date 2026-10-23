//
//  zsign.hpp
//  feather
//
//  Created by HAHALOSAH on 5/22/24.
//

#ifndef zsign_hpp
#define zsign_hpp

#include <stdio.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

bool InjectDyLib(NSString *filePath,
                 NSString *dylibPath,
                 bool weakInject,
                 bool bCreate);

bool ChangeDylibPath(NSString *filePath,
                     NSString *oldPath,
                     NSString *newPath);

bool ListDylibs(NSString *filePath, NSMutableArray *dylibPathsArray);
bool UninstallDylibs(NSString *filePath, NSArray<NSString *> *dylibPathsArray);

int zsign(NSString *app,
          NSString *prov,
          NSString *key,
          NSString *pass,
          NSString *bundleid,
          NSString *displayname,
          NSString *bundleversion,
          NSString *entitlementsFile,
          bool dontGenerateEmbeddedMobileProvision
          );

// Per-invocation variant. Parallelism is attached to the ZAppBundle instance
// so multiple local signing jobs can run concurrently without racing on a
// process-global parallel flag.
int zsignWithOptions(NSString *app,
                     NSString *prov,
                     NSString *key,
                     NSString *pass,
                     NSString *bundleid,
                     NSString *displayname,
                     NSString *bundleversion,
                     NSString *entitlementsFile,
                     bool dontGenerateEmbeddedMobileProvision,
                     bool parallel);

#ifdef __cplusplus
}
#endif

#endif /* zsign_hpp */
