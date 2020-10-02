import 'dart:convert';

import 'package:lemmy_api_client/lemmy_api_client.dart';
import 'package:mobx/mobx.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'accounts_store.g.dart';

/// Store that manages all accounts
class AccountsStore extends _AccountsStore with _$AccountsStore {}

abstract class _AccountsStore with Store {
  ReactionDisposer _saveReactionDisposer;
  ReactionDisposer _pickDefaultsDisposer;

  _AccountsStore() {
    // persistently save settings each time they are changed
    _saveReactionDisposer = reaction(
      (_) => [
        tokens.forEach((k, submap) =>
            MapEntry(k, submap.forEach((k2, v2) => MapEntry(k2, v2)))),
        _defaultAccount,
        _defaultAccounts.asObservable(),
      ],
      (_) => save(),
    );

    // automatically set new default accounts when accounts are added/removed
    _pickDefaultsDisposer = reaction(
      (_) => [
        tokens.forEach((k, submap) =>
            MapEntry(k, submap.forEach((k2, v2) => MapEntry(k2, v2)))),
      ],
      (_) => _assignDefaultAccounts(),
    );
  }

  @action
  void _assignDefaultAccounts() {
    // remove dangling defaults
    _defaultAccounts.entries.map((dft) {
      final instance = dft.key;
      final username = dft.value;
      // if instance or username doesn't exist, remove
      if (!instances.contains(instance) ||
          !tokens[instance].containsKey(username)) {
        return instance;
      }
    }).forEach(_defaultAccounts.remove);
    if (_defaultAccount != null) {
      final instance = _defaultAccount.split('@')[1];
      final username = _defaultAccount.split('@')[0];
      // if instance or username doesn't exist, remove
      if (!instances.contains(instance) ||
          !tokens[instance].containsKey(username)) {
        _defaultAccount = null;
      }
    }

    // set local defaults
    for (final instanceUrl in instances) {
      // if this instance is not in defaults
      if (!_defaultAccounts.containsKey(instanceUrl)) {
        // select first account in this instance, if any
        if (!isAnonymousFor(instanceUrl)) {
          setDefaultAccountFor(instanceUrl, tokens[instanceUrl].keys.first);
        }
      }
    }

    // set global default
    if (_defaultAccount == null) {
      // select first account of first instance
      for (final instanceUrl in instances) {
        // select first account in this instance, if any
        if (!isAnonymousFor(instanceUrl)) {
          setDefaultAccount(instanceUrl, tokens[instanceUrl].keys.first);
        }
      }
    }
  }

  void dispose() {
    _saveReactionDisposer();
    _pickDefaultsDisposer();
  }

  void load() async {
    final prefs = await SharedPreferences.getInstance();

    // I barely understand what I did. Long story short it casts a
    // raw json into a nested ObservableMap
    nestedMapsCast<T>(String key, T f(Map<String, dynamic> json)) =>
        ObservableMap.of(
          (jsonDecode(prefs.getString(key) ?? '{}') as Map<String, dynamic>)
              ?.map(
            (k, e) => MapEntry(
              k,
              ObservableMap.of(
                (e as Map<String, dynamic>)?.map(
                  (k, e) => MapEntry(
                      k, e == null ? null : f(e as Map<String, dynamic>)),
                ),
              ),
            ),
          ),
        );

    // set saved settings or create defaults
    tokens = nestedMapsCast('tokens', (json) => Jwt(json['raw']));
    _defaultAccount = prefs.getString('defaultAccount');
    _defaultAccounts = ObservableMap.of(Map.castFrom(
        jsonDecode(prefs.getString('defaultAccounts') ?? 'null') ?? {}));
  }

  void save() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('defaultAccount', _defaultAccount);
    await prefs.setString('defaultAccounts', jsonEncode(_defaultAccounts));
    await prefs.setString('tokens', jsonEncode(tokens));
  }

  /// Map containing JWT tokens of specific users.
  /// If a token is in this map, the user is considered logged in
  /// for that account.
  /// `tokens['instanceUrl']['username']`
  @observable
  ObservableMap<String, ObservableMap<String, Jwt>> tokens;

  /// default account for a given instance
  /// map where keys are instanceUrls and values are usernames
  @observable
  ObservableMap<String, String> _defaultAccounts;

  /// default account for the app
  /// It is in a form of `username@instanceUrl`
  @observable
  String _defaultAccount;

  @computed
  String get defaultUsername {
    if (_defaultAccount == null) {
      return null;
    }

    return _defaultAccount.split('@')[0];
  }

  @computed
  String get defaultInstanceUrl {
    if (_defaultAccount == null) {
      return null;
    }

    return _defaultAccount.split('@')[1];
  }

  String defaultUsernameFor(String instanceUrl) => Computed(() {
        if (isAnonymousFor(instanceUrl)) {
          return null;
        }

        return _defaultAccounts[instanceUrl];
      }).value;

  @computed
  Jwt get defaultToken {
    if (_defaultAccount == null) {
      return null;
    }

    final userTag = _defaultAccount.split('@');
    return tokens[userTag[1]][userTag[0]];
  }

  Jwt defaultTokenFor(String instanceUrl) => Computed(() {
        if (isAnonymousFor(instanceUrl)) {
          return null;
        }

        return tokens[instanceUrl][_defaultAccounts[instanceUrl]];
      }).value;

  /// sets globally default account
  @action
  void setDefaultAccount(String instanceUrl, String username) {
    _defaultAccount = '$username@$instanceUrl';
  }

  /// sets default account for given instance
  @action
  void setDefaultAccountFor(String instanceUrl, String username) {
    _defaultAccounts[instanceUrl] = username;
  }

  /// An instance is considered anonymous if it was not
  /// added or there are no accounts assigned to it.
  bool isAnonymousFor(String instanceUrl) => Computed(() {
        if (!instances.contains(instanceUrl)) {
          return true;
        }

        return tokens[instanceUrl].isEmpty;
      }).value;

  /// `true` if no added instance has an account assigned to it
  @computed
  bool get hasNoAccount => loggedInInstances.isEmpty;

  @computed
  Iterable<String> get instances => tokens.keys;

  @computed
  Iterable<String> get loggedInInstances =>
      instances.where((e) => !isAnonymousFor(e));

  /// adds a new account
  /// if it's the first account ever the account is
  /// set as default for the app
  /// if it's the first account for an instance the account is
  /// set as default for that instance
  @action
  Future<void> addAccount(
    String instanceUrl,
    String usernameOrEmail,
    String password,
  ) async {
    if (!instances.contains(instanceUrl)) {
      throw Exception('No such instance was added');
    }

    final lemmy = LemmyApi(instanceUrl).v1;

    final token = await lemmy.login(
      usernameOrEmail: usernameOrEmail,
      password: password,
    );
    final userData =
        await lemmy.getSite(auth: token.raw).then((value) => value.myUser);

    tokens[instanceUrl][userData.name] = token;
  }

  /// adds a new instance with no accounts associated with it.
  /// Additionally makes a test `GET /site` request to check if the instance exists.
  /// Check is skipped when [assumeValid] is `true`
  @action
  Future<void> addInstance(
    String instanceUrl, {
    bool assumeValid = false,
  }) async {
    if (instances.contains(instanceUrl)) {
      throw Exception('This instance has already been added');
    }

    if (!assumeValid) {
      try {
        await LemmyApi(instanceUrl).v1.getSite();
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {
        throw Exception('This instance seems to not exist');
      }
    }

    tokens[instanceUrl] = ObservableMap();
  }

  /// This also removes all accounts assigned to this instance
  @action
  void removeInstance(String instanceUrl) {
    tokens.remove(instanceUrl);
  }

  @action
  void removeAccount(String instanceUrl, String username) {
    tokens[instanceUrl].remove(username);
  }
}