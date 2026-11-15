import 'package:flutter/material.dart';

const List<String> kQuickReactions = ['❤️', '😂', '😮', '😢', '🙏', '👍', '🔥'];

const Map<String, List<String>> kEmojiGroups = {
  '😀': [
    '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩',
    '😘', '😗', '😚', '😙', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🤐', '🤨',
    '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢',
    '🤮', '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '😎', '🤓', '🧐', '😕', '😟', '🙁', '😮', '😯',
    '😲', '😳', '🥺', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩',
    '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '💩', '🤡', '👻', '👽', '🤖', '😺', '😻',
  ],
  '👍': [
    '👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '🤙', '👈', '👉', '👆', '👇', '☝️', '✋', '🤚', '🖐️',
    '🖖', '👋', '👏', '🙌', '👐', '🤲', '🤝', '🙏', '✍️', '💪', '🦾', '👀', '👁️', '👅', '👄', '💋',
    '🧠', '🫶', '👶', '🧒', '👦', '👧', '🧑', '👨', '👩', '🧔', '👴', '👵', '🙋', '🙆', '🙅', '🤷',
  ],
  '❤️': [
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖',
    '💘', '💝', '💟', '✨', '⭐', '🌟', '💫', '🔥', '💯', '✅', '❌', '⚡', '💥', '💢', '💤', '🎉',
    '🎊', '🎁', '🎈', '🏆', '🥇', '🎯', '🎮', '🎧', '🎵', '🎶', '📸', '💡', '📌', '📍', '⏰', '💬',
  ],
  '🐶': [
    '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔',
    '🐧', '🐦', '🦄', '🐝', '🦋', '🐢', '🐍', '🐙', '🐬', '🐳', '🌸', '🌹', '🌻', '🌷', '🌲', '🍀',
    '🌙', '☀️', '⛅', '🌈', '❄️', '☔', '🌊', '🍎', '🍓', '🍉', '🍕', '🍔', '🍟', '🌮', '🍩', '☕',
  ],
};

class EmojiPanel extends StatefulWidget {
  final ValueChanged<String> onPick;
  final VoidCallback? onBackspace;
  const EmojiPanel({super.key, required this.onPick, this.onBackspace});

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  String _group = kEmojiGroups.keys.first;

  @override
  Widget build(BuildContext context) {
    final emojis = kEmojiGroups[_group]!;
    return Container(
      height: 280,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Row(
            children: [
              for (final g in kEmojiGroups.keys)
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _group = g),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: g == _group
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(g, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                ),
              if (widget.onBackspace != null)
                IconButton(
                  icon: const Icon(Icons.backspace_outlined),
                  onPressed: widget.onBackspace,
                ),
            ],
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 46,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: emojis.length,
              itemBuilder: (_, i) => InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => widget.onPick(emojis[i]),
                child: Center(child: Text(emojis[i], style: const TextStyle(fontSize: 26))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
