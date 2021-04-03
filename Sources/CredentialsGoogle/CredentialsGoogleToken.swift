/**
 * Copyright IBM Corporation 2016, 2017
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Kitura
import KituraNet
import LoggerAPI
import Credentials
import Foundation

// MARK CredentialsGoogleToken

/// Authentication using Google OAuth token.
public class CredentialsGoogleToken: CredentialsPluginProtocol {
    
    /// The name of the plugin.
    public var name: String {
        return "GoogleToken"
    }
    
    /// An indication as to whether the plugin is redirecting or not.
    public var redirecting: Bool {
        return false
    }
    
    /// The time in seconds since the user profile was generated that the access token will be considered valid.
    public let tokenTimeToLive: TimeInterval?

    private var delegate: UserProfileDelegate?
    
    /// A delegate for `UserProfile` manipulation.
    public var userProfileDelegate: UserProfileDelegate? {
        return delegate
    }
    
    /// Initialize a `CredentialsGoogleToken` instance.
    ///
    /// - Parameter options: A dictionary of plugin specific options. The keys are defined in `CredentialsGoogleOptions`.
    public init(options: [String:Any]?=nil, tokenTimeToLive: TimeInterval? = nil) {
        delegate = options?[CredentialsGoogleOptions.userProfileDelegate] as? UserProfileDelegate
        self.tokenTimeToLive = tokenTimeToLive
    }
    
    /// User profile cache.
    public var usersCache: NSCache<NSString, BaseCacheElement>?
    
    /// Authenticate incoming request using Google OAuth token.
    ///
    /// - Parameter request: The `RouterRequest` object used to get information
    ///                     about the request.
    /// - Parameter response: The `RouterResponse` object used to respond to the
    ///                       request.
    /// - Parameter options: The dictionary of plugin specific options.
    /// - Parameter onSuccess: The closure to invoke in the case of successful authentication.
    /// - Parameter onFailure: The closure to invoke in the case of an authentication failure.
    /// - Parameter onPass: The closure to invoke when the plugin doesn't recognize the
    ///                     authentication token in the request.
    /// - Parameter inProgress: The closure to invoke to cause a redirect to the login page in the
    ///                     case of redirecting authentication.
    public func authenticate(request: RouterRequest, response: RouterResponse,
                             options: [String:Any], onSuccess: @escaping (UserProfile) -> Void,
                             onFailure: @escaping (HTTPStatusCode?, [String:String]?) -> Void,
                             onPass: @escaping (HTTPStatusCode?, [String:String]?) -> Void,
                             inProgress: @escaping () -> Void) {
        if let type = request.headers["X-token-type"], type == name {
            if let token = request.headers["access_token"] {
                #if os(Linux)
                    let key = NSString(string: token)
                #else
                    let key = token as NSString
                #endif
                if let cached = usersCache?.object(forKey: key) {
                    if let ttl = tokenTimeToLive {
                        if Date() < cached.createdAt.addingTimeInterval(ttl) {
                            onSuccess(cached.userProfile)
                            return
                        }
                        // If current time is later than time to live, continue to standard token authentication.
                        // Don't need to evict token, since it will replaced if the token is successfully autheticated.
                    } else {
                        // No time to live set, use token until it is evicted from the cache
                        onSuccess(cached.userProfile)
                        return
                    }
                }
                
                var requestOptions: [ClientRequest.Options] = []
                requestOptions.append(.schema("https://"))
                requestOptions.append(.hostname("www.googleapis.com"))
                requestOptions.append(.method("GET"))
                requestOptions.append(.path("/oauth2/v3/userinfo?access_token=\(token)"))
                var headers = [String:String]()
                headers["Accept"] = "application/json"
                requestOptions.append(.headers(headers))
                
                let req = HTTP.request(requestOptions) { response in
                    if let response = response, response.statusCode == HTTPStatusCode.OK {
                        do {
                            var body = Data()
                            try response.readAllData(into: &body)
                            if let dictionary = try JSONSerialization.jsonObject(with: body, options: []) as? [String : Any],
                            let userProfile = createUserProfile(from: dictionary, for: self.name) {
                                if let delegate = self.delegate ?? options[CredentialsGoogleOptions.userProfileDelegate] as? UserProfileDelegate {
                                    delegate.update(userProfile: userProfile, from: dictionary)
                                }

                                let newCacheElement = BaseCacheElement(profile: userProfile)
                                #if os(Linux)
                                    let key = NSString(string: token)
                                #else
                                    let key = token as NSString
                                #endif
                                self.usersCache?.setObject(newCacheElement, forKey: key)
                                onSuccess(userProfile)
                                return
                            }
                        } catch {
                            Log.error("Failed to read Google response")
                        }
                    }
                    Log.error("Google response: \(String(describing: response)); statusCode: \(String(describing: response?.statusCode))")
                    onFailure(nil, nil)
                }
                req.end()
            }
            else {
                Log.error("Google: No access_token")
                onFailure(nil, nil)
            }
        }
        else {
            Log.info("Google: No token type")
            onPass(nil, nil)
        }
    }
}
