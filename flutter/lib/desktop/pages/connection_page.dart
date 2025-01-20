// main window right pane

import 'dart:async';
import 'dart:convert';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:intl/intl.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../common/widgets/autocomplete.dart';
import '../../models/platform_model.dart';
import '../widgets/button.dart';
import 'package:flutter_hbb/models/encrypt_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnlineStatusWidget extends StatefulWidget {
  const OnlineStatusWidget({Key? key, this.onSvcStatusChanged})
      : super(key: key);

  final VoidCallback? onSvcStatusChanged;

  @override
  State<OnlineStatusWidget> createState() => _OnlineStatusWidgetState();
}

/// State for the connection page.
class _OnlineStatusWidgetState extends State<OnlineStatusWidget> {
  final _svcStopped = Get.find<RxBool>(tag: 'stop-service');
  final _svcIsUsingPublicServer = true.obs;
  Timer? _updateTimer;

  double get em => 14.0;
  double? get height => bind.isIncomingOnly() ? null : em * 3;

  void onUsePublicServerGuide() {
    const url = "https://rustdesk.com/pricing.html";
    canLaunchUrlString(url).then((can) {
      if (can) {
        launchUrlString(url);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(Duration(seconds: 1), () async {
      updateStatus();
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isIncomingOnly = bind.isIncomingOnly();
    startServiceWidget() => Offstage(
          offstage: !_svcStopped.value,
          child: InkWell(
                  onTap: () async {
                    await start_service(true);
                  },
                  child: Text(translate("Start service"),
                      style: TextStyle(
                          decoration: TextDecoration.underline, fontSize: em)))
              .marginOnly(left: em),
        );

    setupServerWidget() => Flexible(
          child: Offstage(
            offstage: !(!_svcStopped.value &&
                stateGlobal.svcStatus.value == SvcStatus.ready &&
                _svcIsUsingPublicServer.value),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(', ', style: TextStyle(fontSize: em)),
                Flexible(
                  child: InkWell(
                    onTap: onUsePublicServerGuide,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            translate('setup_server_tip'),
                            style: TextStyle(
                                decoration: TextDecoration.underline,
                                fontSize: em),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              ],
            ),
          ),
        );

    basicWidget() => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              height: 8,
              width: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: _svcStopped.value ||
                        stateGlobal.svcStatus.value == SvcStatus.connecting
                    ? kColorWarn
                    : (stateGlobal.svcStatus.value == SvcStatus.ready
                        ? Color.fromARGB(255, 50, 190, 166)
                        : Color.fromARGB(255, 224, 79, 95)),
              ),
            ).marginSymmetric(horizontal: em),
            Container(
              width: isIncomingOnly ? 226 : null,
              child: _buildConnStatusMsg(),
            ),
            // stop
            if (!isIncomingOnly) startServiceWidget(),
            // ready && public
            // No need to show the guide if is custom client.
            if (!isIncomingOnly) setupServerWidget(),
          ],
        );

    return Container(
      height: height,
      child: Obx(() => isIncomingOnly
          ? Column(
              children: [
                basicWidget(),
                Align(
                        child: startServiceWidget(),
                        alignment: Alignment.centerLeft)
                    .marginOnly(top: 2.0, left: 22.0),
              ],
            )
          : basicWidget()),
    ).paddingOnly(right: isIncomingOnly ? 8 : 0);
  }

  _buildConnStatusMsg() {
    widget.onSvcStatusChanged?.call();
    return Text(
      _svcStopped.value
          ? translate("Service is not running")
          : stateGlobal.svcStatus.value == SvcStatus.connecting
              ? translate("connecting_status")
              : stateGlobal.svcStatus.value == SvcStatus.notReady
                  ? translate("not_ready_status")
                  : translate('Ready'),
      style: TextStyle(fontSize: em),
    );
  }

  updateStatus() async {
    final status =
        jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
    final statusNum = status['status_num'] as int;
    if (statusNum == 0) {
      stateGlobal.svcStatus.value = SvcStatus.connecting;
    } else if (statusNum == -1) {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    } else if (statusNum == 1) {
      stateGlobal.svcStatus.value = SvcStatus.ready;
    } else {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    }
    _svcIsUsingPublicServer.value = await bind.mainIsUsingPublicServer();
  }
}

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({Key? key}) : super(key: key);

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

/// State for the connection page.
class _ConnectionPageState extends State<ConnectionPage>
    with SingleTickerProviderStateMixin, WindowListener {
  final _idController = IDTextEditingController();
  final sqmController = TextEditingController();

  final RxBool _idInputFocused = false.obs;

  bool isWindowMinimized = false;
  List<Peer> peers = [];

  bool isPeersLoading = false;
  bool isPeersLoaded = false;

  String DateFormats2 = "-";

  @override
  Future<void> initState() async {
    super.initState();
    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }
    Get.put<IDTextEditingController>(_idController);
    windowManager.addListener(this);

    SharedPreferences prefs = await SharedPreferences.getInstance();
    // 获取 'decryptJzrqTxt' 值并赋值给 sqmController.text
    String sqmControllertext = prefs.getString('decryptJzrqTxt') ?? "";
    if (sqmControllertext.isNotEmpty) {
      sqmController.text = sqmControllertext;
    }

    // 获取 'decryptJzrq' 值并进行日期格式化
    int decryptJzrq = prefs.getInt('decryptJzrq') ?? 0;
    if (decryptJzrq > 0) {
      DateTime DateFormats1 = DateTime.fromMillisecondsSinceEpoch(decryptJzrq);
      var DateFormats3 = DateFormat('yyyy年MM月dd日').format(DateFormats1);
      DateFormats2 = "授权截止日期：$DateFormats3";
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    windowManager.removeListener(this);
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }

  @override
  void onWindowEvent(String eventName) {
    super.onWindowEvent(eventName);
    if (eventName == 'minimize') {
      isWindowMinimized = true;
    } else if (eventName == 'maximize' || eventName == 'restore') {
      if (isWindowMinimized && isWindows) {
        // windows can't update when minimized.
        Get.forceAppUpdate();
      }
      isWindowMinimized = false;
    }
  }

  @override
  void onWindowEnterFullScreen() {
    // Remove edge border by setting the value to zero.
    stateGlobal.resizeEdgeSize.value = 0;
  }

  @override
  void onWindowLeaveFullScreen() {
    // Restore edge border to default edge size.
    stateGlobal.resizeEdgeSize.value = stateGlobal.isMaximized.isTrue
        ? kMaximizeEdgeSize
        : windowResizeEdgeSize;
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    bind.mainOnMainWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    final isOutgoingOnly = bind.isOutgoingOnly();
    return Column(
      children: [
        Expanded(
            child: Column(
          children: [
            Row(
              children: [
                Flexible(child: _buildRemoteIDTextField(context)),
                const SizedBox(
                  width: 5,
                ),
                Flexible(child: _buildSQTextField(context)),
              ],
            ).marginOnly(top: 22),
            SizedBox(height: 12),
            Divider().paddingOnly(right: 12),
            Expanded(child: PeerTabPage()),
          ],
        ).paddingOnly(left: 12.0)),
        if (!isOutgoingOnly) const Divider(height: 1),
        if (!isOutgoingOnly) OnlineStatusWidget()
      ],
    );
  }

  /// Callback for the connect button.
  /// Connects to the selected peer.
  void onConnect({bool isFileTransfer = false}) {
    var id = _idController.id;
    connect(context, id, isFileTransfer: isFileTransfer);
  }

  void onKefu() {
    const url = "https://t.me/MMM_Eric";
    canLaunchUrlString(url).then((can) {
      if (can) {
        launchUrlString(url);
      }
    });
  }

  void onSq() async {
    String privateKey = '''
MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBAMwpcRDWemC3SXmc
k4Md2dQxbXr8daWiPdw8u8JtsRyxNN7+AbJlO8y+3bEN7BFSdWppl5+fa8aWqG6u
RFDvGmajnyXBv1zvR39Ehncj5NQskfeaplu/ycer8EuVMv0NWrCncbTKx3MtYc0D
MAzB/sGNo0RGj/NzgDn3xd4/OKpDAgMBAAECgYEAvWoZd1i1s3N5XLXS+gvA5Chz
fW4qrGBI6kMCpBFnB8q01cptwpg/kebnAXR8N1n8i5ypyrN6p4VxgTZ3NWuQXk16
G4UcZcqRciButOs0E+W4Ot5+PMLuutcsFW/uYtaTRIMWHLV0GuHJjUCbLKKJolFc
thMggXOwy6EucL2NALkCQQD7koP0UiHTFyMHmdHKuAESQFU4fNzypzBlvOBBNX7T
1caLiCoRjUCDEGf8ABE4CTMeDT1SVBgLkfg0o3SFxI2vAkEAz8FQTFWerhnIGkdE
bm/togRUk/LbYIg3YWMfsaDhMU3ue2h4ojXWvNduEjiLm9oX1MsmsBmZdpCRSW4/
5AeFrQJBAKQ3c+Ncaa/9fmRLyGJn0mszi22gNCpBcJo4vLpUTUHCXiRe8fcbGW10
nCwnbxYBC1kmk0zWkAudcUQLHtjjAQkCQHMu+4UG504hbybaol8UYUy1V+sa93QC
saml2lmSF6hNS85R8qgEb4UNb7JcdVK4TQQmidGSr9njdxmeLYAQh5UCQDlMuw0H
25UPw+9QMujcT3UTvABy0lOXRInZgEUU6YAjy0rNVUxLeNoyXlObRTlpoyVz58Er
fp2bts3jaD4PsSU=
  ''';

    String sqm = sqmController.text;

    SharedPreferences prefs = await SharedPreferences.getInstance();

    if (sqm.isEmpty) {
      showToast("授权码不能为空，请输入");
      setState(() {
        DateFormats2 = "-";
      });
      prefs.clear();
    } else {
      try {
        String decrypt = EncryptUtils.rsaDecrypt(sqm, privateKey);
        var millisecondsSinceEpochi = DateTime.now().millisecondsSinceEpoch;
        if (int.parse(decrypt) <= millisecondsSinceEpochi) {
          showToast("授权码已过期，请联系客服购买");
          setState(() {
            DateFormats2 = "-";
          });
          prefs.clear();
        } else {
          DateTime DateFormats1 =
              DateTime.fromMillisecondsSinceEpoch(int.parse(decrypt));
          var DateFormats4 = DateFormat('yyyy年MM月dd日').format(DateFormats1);

          setState(() {
            DateFormats2 = "授权截止日期：$DateFormats4";
          });

          showToast('授权截止日期：$DateFormats4');
          prefs.setInt("decryptJzrq", int.parse(decrypt));
          prefs.setString("decryptJzrqTxt", sqm);
        }
      } catch (e) {
        showToast("授权码格式错误，请联系客服购买");
        setState(() {
          DateFormats2 = "-";
        });
        prefs.clear();
      }
    }
  }

  Future<void> _fetchPeers() async {
    setState(() {
      isPeersLoading = true;
    });
    await Future.delayed(Duration(milliseconds: 100));
    peers = await getAllPeers();
    setState(() {
      isPeersLoading = false;
      isPeersLoaded = true;
    });
  }

  /// UI for the remote ID TextField.
  /// Search for a peer.
  Widget _buildRemoteIDTextField(BuildContext context) {
    var w = Container(
      width: 320 + 20 * 2,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(13)),
          border: Border.all(color: Theme.of(context).colorScheme.background)),
      child: Ink(
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                    child: Row(
                  children: [
                    AutoSizeText(
                      translate('Control Remote Desktop'),
                      maxLines: 1,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.merge(TextStyle(height: 1)),
                    ).marginOnly(right: 4),
                    Tooltip(
                      waitDuration: Duration(milliseconds: 300),
                      message: translate("id_input_tip"),
                      child: Icon(
                        Icons.help_outline_outlined,
                        size: 16,
                        color: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.color
                            ?.withOpacity(0.5),
                      ),
                    ),
                  ],
                )),
              ],
            ).marginOnly(bottom: 15),
            Row(
              children: [
                Expanded(
                    child: Autocomplete<Peer>(
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    if (textEditingValue.text == '') {
                      return const Iterable<Peer>.empty();
                    } else if (peers.isEmpty && !isPeersLoaded) {
                      Peer emptyPeer = Peer(
                        id: '',
                        username: '',
                        hostname: '',
                        alias: '',
                        platform: '',
                        tags: [],
                        hash: '',
                        password: '',
                        forceAlwaysRelay: false,
                        rdpPort: '',
                        rdpUsername: '',
                        loginName: '',
                      );
                      return [emptyPeer];
                    } else {
                      String textWithoutSpaces =
                          textEditingValue.text.replaceAll(" ", "");
                      if (int.tryParse(textWithoutSpaces) != null) {
                        textEditingValue = TextEditingValue(
                          text: textWithoutSpaces,
                          selection: textEditingValue.selection,
                        );
                      }
                      String textToFind = textEditingValue.text.toLowerCase();

                      return peers
                          .where((peer) =>
                              peer.id.toLowerCase().contains(textToFind) ||
                              peer.username
                                  .toLowerCase()
                                  .contains(textToFind) ||
                              peer.hostname
                                  .toLowerCase()
                                  .contains(textToFind) ||
                              peer.alias.toLowerCase().contains(textToFind))
                          .toList();
                    }
                  },
                  fieldViewBuilder: (
                    BuildContext context,
                    TextEditingController fieldTextEditingController,
                    FocusNode fieldFocusNode,
                    VoidCallback onFieldSubmitted,
                  ) {
                    fieldTextEditingController.text = _idController.text;
                    Get.put<TextEditingController>(fieldTextEditingController);
                    fieldFocusNode.addListener(() async {
                      _idInputFocused.value = fieldFocusNode.hasFocus;
                      if (fieldFocusNode.hasFocus && !isPeersLoading) {
                        _fetchPeers();
                      }
                    });
                    final textLength =
                        fieldTextEditingController.value.text.length;
                    // select all to facilitate removing text, just following the behavior of address input of chrome
                    fieldTextEditingController.selection =
                        TextSelection(baseOffset: 0, extentOffset: textLength);
                    return Obx(() => TextField(
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.visiblePassword,
                          focusNode: fieldFocusNode,
                          style: const TextStyle(
                            fontFamily: 'WorkSans',
                            fontSize: 22,
                            height: 1.4,
                          ),
                          maxLines: 1,
                          cursorColor:
                              Theme.of(context).textTheme.titleLarge?.color,
                          decoration: InputDecoration(
                              filled: false,
                              counterText: '',
                              hintText: _idInputFocused.value
                                  ? null
                                  : translate('Enter Remote ID'),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 15, vertical: 13)),
                          controller: fieldTextEditingController,
                          inputFormatters: [IDTextInputFormatter()],
                          onChanged: (v) {
                            _idController.id = v;
                          },
                          onSubmitted: (_) {
                            onConnect();
                          },
                        ));
                  },
                  onSelected: (option) {
                    setState(() {
                      _idController.id = option.id;
                      FocusScope.of(context).unfocus();
                    });
                  },
                  optionsViewBuilder: (BuildContext context,
                      AutocompleteOnSelected<Peer> onSelected,
                      Iterable<Peer> options) {
                    double maxHeight = options.length * 50;
                    if (options.length == 1) {
                      maxHeight = 52;
                    } else if (options.length == 3) {
                      maxHeight = 146;
                    } else if (options.length == 4) {
                      maxHeight = 193;
                    }
                    maxHeight = maxHeight.clamp(0, 200);

                    return Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 5,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(5),
                              child: Material(
                                elevation: 4,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: maxHeight,
                                    maxWidth: 319,
                                  ),
                                  child: peers.isEmpty && isPeersLoading
                                      ? Container(
                                          height: 80,
                                          child: Center(
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ))
                                      : Padding(
                                          padding:
                                              const EdgeInsets.only(top: 5),
                                          child: ListView(
                                            children: options
                                                .map((peer) =>
                                                    AutocompletePeerTile(
                                                        onSelect: () =>
                                                            onSelected(peer),
                                                        peer: peer))
                                                .toList(),
                                          ),
                                        ),
                                ),
                              ))),
                    );
                  },
                )),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 13.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Button(
                    isOutline: true,
                    onTap: () => onConnect(isFileTransfer: true),
                    text: "Transfer file",
                  ),
                  const SizedBox(
                    width: 17,
                  ),
                  Button(onTap: onConnect, text: "Connect"),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return Container(
        constraints: const BoxConstraints(maxWidth: 600), child: w);
  }

  Widget _buildSQTextField(BuildContext context) {
    var w = Container(
      width: 320 + 20 * 2,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(13)),
          border: Border.all(color: Theme.of(context).colorScheme.background)),
      child: Ink(
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                    child: Row(
                  children: [
                    Text(
                      "授权",
                      maxLines: 1,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.merge(TextStyle(height: 1)),
                    ).marginOnly(right: 4),
                    Tooltip(
                      waitDuration: Duration(milliseconds: 300),
                      message: "授权解锁高级功能",
                      child: Icon(
                        Icons.help_outline_outlined,
                        size: 16,
                        color: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.color
                            ?.withOpacity(0.5),
                      ),
                    ).marginOnly(right: 4),
                    Text(
                      DateFormats2,
                      key: ValueKey(DateFormats2),
                      maxLines: 1,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.merge(TextStyle(height: 1)),
                    ).marginOnly(right: 4),
                  ],
                )),
              ],
            ).marginOnly(bottom: 15),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    style: const TextStyle(
                      fontFamily: 'WorkSans',
                      fontSize: 22,
                      height: 1.4,
                    ),
                    maxLines: 1,
                    cursorColor: Theme.of(context).textTheme.titleLarge?.color,
                    decoration: InputDecoration(
                      hintText: "请输入授权码",
                      prefixIcon: Icon(Icons.key),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 15, vertical: 13),
                    ),
                    controller: sqmController,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 13.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Button(
                    onTap: onSq,
                    text: "激活授权",
                  ),
                  const SizedBox(
                    width: 17,
                  ),
                  TextButton.icon(
                    icon: Icon(Icons.telegram_outlined),
                    label: Text("联系客服"),
                    onPressed: onKefu,
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return Container(
        constraints: const BoxConstraints(maxWidth: 600), child: w);
  }
}
