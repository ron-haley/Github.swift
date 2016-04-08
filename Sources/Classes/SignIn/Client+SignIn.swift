//
//  Client+SignIn.swift
//  GithubSwift
//
//  Created by Khoa Pham on 03/04/16.
//  Copyright © 2016 Fantageek. All rights reserved.
//

import Foundation
import RxSwift

public extension Client {
  
  public static var callBackURLVariable: Variable<NSURL?> = Variable(nil)
  public static var urlOpener: URLOpenerType = URLOpener()
  
  // Attempts to authenticate as the given user.
  //
  // Authentication is done using a native OAuth flow. This allows apps to avoid
  // presenting a webpage, while minimizing the amount of time the client app
  // needs the user's password.
  //
  // If `user` has two-factor authentication turned on and `oneTimePassword` is
  // not provided, the authorization will be rejected with an error whose `code` is
  // `OCTClientErrorTwoFactorAuthenticationOneTimePasswordRequired`. The behavior
  // then depends on the `OCTClientOneTimePasswordMedium` that the user has set:
  //
  //  * If the user has chosen SMS as their authentication method, they will be
  //    sent a one-time password _each time_ this method is invoked.
  //  * If the user has chosen to use an app for authentication, they must open
  //    their chosen app and use the one-time password it presents.
  //
  // You can then invoke this method again to request authorization using the
  // one-time password entered by the user.
  //
  // **NOTE:** You must invoke +setClientID:clientSecret: before using this
  // method.
  //
  // user            - The user to authenticate as. The `user` property of the
  //                   returned client will be set to this object. This must not be nil.
  // password        - The user's password. Cannot be nil.
  // oneTimePassword - The one-time password to approve the authorization request.
  //                   This may be nil if you have no one-time password to
  //                   provide, which will usually be the case unless you've
  //                   already requested authorization, `user` has two-factor
  //                   authentication on, and the user has entered their one-time
  //                   password.
  // scopes          - The scopes to request access to. These values can be
  //                   bitwise OR'd together to request multiple scopes.
  // note            - A human-readable string to remind the user what this OAuth
  //                   token is used for. May be nil.
  // noteURL         - A URL to remind the user what the OAuth token is used for.
  //                   May be nil.
  // fingerprint     - A unique string to distinguish one authorization from
  //                   others created for the same client ID and user. May be nil.
  //
  // Returns a signal which will send an OCTClient then complete on success, or
  // else error. If the server is too old to support this request, an error will
  // be sent with code `OCTClientErrorUnsupportedServer`.
  public static func signIn(user user: User, password: String,
                                 scopes: AuthorizationScopes,
                                 oneTimePassword: String? = nil,
                                 note: String? = nil, noteURL: NSURL? = nil,
                                 fingerprint: String? = nil) -> Observable<Client> {
    
    let clientID = Client.Config.clientID
    let clientSecret = Client.Config.clientSecret
    
    assert(!clientID.isEmpty)
    assert(!clientSecret.isEmpty)
    
    // Request Descriptor
    let path = "authorizations/clients/\(clientID)"
    var params = [
      "scopes": scopes.values.joinWithSeparator(","),
      "client_secret": clientSecret,
    ]
    
    if let note = note {
      params["note"] = note
    }
    
    if let noteURLString = noteURL?.absoluteString {
      params["note_url"] = noteURLString
    }
    
    if let fingerprint = fingerprint {
      params["fingerprint"] = fingerprint
    }
    
    let requestDescriptor = RequestDescriptor().then {
      $0.method = .PUT
      $0.path = path
      $0.parameters = params
      $0.headers = [
        "Accept": "application/vnd.github.\(Client.Constant.miragePreviewAPIVersion)+json"
      ]
      
      if let (key, value) = Helper.authorizationHeader(user.rawLogin, password: password) {
        $0.headers[key] = value
      }
    }

    // Authorize
    func authorize(user: User) -> Observable<(Client, Authorization)> {
      return Observable<(Client, Authorization)>.deferred {
        let client = Client(unauthenticatedUser: user)
        
        let observable = client.enqueue(requestDescriptor).map {
          return Parser.one($0.jsonArray) as Authorization
        }
      
        return Observable.combineLatest(Observable<Client>.just(client), observable) {
          return ($0, $1)
        }
      }
    }
    
    func reauthorizeIfNeeded(client: Client, authorization: Authorization) -> Observable<(Client, Authorization)> {
      // To increase security, tokens are no longer returned when the authorization
      // already exists. If that happens, we need to delete the existing
      // authorization for this app and create a new one, so we end up with a token
      // of our own.
      //
      // The `fingerprint` field provided will be used to ensure uniqueness and
      // avoid deleting unrelated tokens.
      if authorization.token.isEmpty {
        let requestDescriptor = requestDescriptor
        requestDescriptor.then {
          $0.path = "authorizations/\(authorization.objectID)"
          $0.method = .DELETE
          
          if let oneTimePassword = oneTimePassword {
            $0.headers[Client.Constant.oneTimePasswordHeaderField] = oneTimePassword
          }
        }
        
        return client.enqueue(requestDescriptor).flatMap { _ in
          return authorize(user)
        }
      } else {
        return Observable<(Client, Authorization)>.just((client, authorization))
      }
    }
    
    func handleError(error: NSError) -> Observable<(Client, Authorization)> {
      if error.code == ErrorCode.UnsupportedServerScheme.rawValue {
        let secureServer = Server.HTTPSEnterpriseServer(user.server)
        let secureUser = User(rawLogin: user.rawLogin, server: secureServer)
        
        return authorize(secureUser)
      }
     
      var error = error
      
      if let statusCode = error.userInfo[ErrorKey.HTTPStatusCodeKey.rawValue] as? Int {
        if statusCode == ErrorCode.NotFound.rawValue {
          if error.userInfo[ErrorKey.OAuthScopesStringKey.rawValue] != nil {
            error = Error.tokenUnsupportedError()
          } else {
            error = Error.unsupportedVersionError()
          }
        }
      }
      
      return Observable<(Client, Authorization)>.error(error)
    }
    
    return
      authorize(user)
      .flatMap { (client: Client, authorization: Authorization) in
        return reauthorizeIfNeeded(client, authorization: authorization)
      }
      .catchError { error in
        let error = error as NSError
        return handleError(error)
      }
      .map { (client: Client, authorization: Authorization) in
        client.token = authorization.token
        
        return client
      }
      .debug("+signInAsUser: \(user) password:oneTimePassword:scopes:")
  }
  
  public static func authorizeUsingWebBrowser(server: Server, scopes: AuthorizationScopes) -> Observable<String> {
    let clientID = Client.Config.clientID
    
    assert(!clientID.isEmpty)
    
    let observable = Observable<String>.create({ (observer) -> Disposable in
      let uuid = NSUUID().UUIDString
      
      // For any matching callback URL, send the temporary code to our
      // subscriber.
      //
      // This should be set up before opening the URL below, or we may
      // miss values on self.callbackURLs.
      let disposable =
        callBackURLVariable
          .asObservable()
          .flatMap { (url: NSURL?) -> Observable<String> in
            let queryArguments = url?.queryArguments ?? [:]
            
            if queryArguments["state"] == uuid {
              return Observable<String>.just(queryArguments["code"] ?? "")
            } else {
              return Observable<String>.empty()
            }
          }
          .take(1)
          .subscribe(observer)
      
      let scope = scopes.values.joinWithSeparator(",")
      
      // Trim trailing slashes from URL entered by the user, so we don't open
      // their web browser to a URL that contains empty path components.
      let slashSet = NSCharacterSet(charactersInString: "/")
      let baseURLString = server.baseWebURL.absoluteString.stringByTrimmingCharactersInSet(slashSet)
      let URLString = "\(baseURLString)/login/oauth/authorize?client_id=\(clientID)&scope=\(scope)&state=\(uuid)"
      
      if let webURL = NSURL(string: URLString) {
        if !urlOpener.openURL(webURL) {
          observer.onError(Error.openingBrowserError(webURL))
        }
      }
      
      return disposable
    }).debug("+authorizeWithServerUsingWebBrowser: \(server) scopes:")
    
    return observable
  }
  
  // Notifies any waiting login processes that authentication has completed.
  //
  // This only affects authentication started with
  // +signInToServerUsingWebBrowser:scopes:. Invoking this method will allow
  // the originating login process to continue. If `callbackURL` does not
  // correspond to any in-progress logins, nothing will happen.
  //
  // callbackURL - The URL that the app was opened with. This must not be nil.
  public static func completeSignIn(callbackURL url: NSURL) {
    callBackURLVariable.value = url
  }
}
