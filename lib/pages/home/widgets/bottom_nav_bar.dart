import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:campus_app/core/themes.dart';
import 'package:campus_app/pages/home/page_navigator.dart';
import 'package:campus_app/pages/home/widgets/bottom_nav_bar_item.dart';

/// Creates the bottom navigation bar that lets the user switch between different pages.
///
/// The items are shown in a horizontally scrollable row. The active item is
/// automatically scrolled into view.
class BottomNavBar extends StatefulWidget {
  /// Needs the currently active page in order to highlight it
  final PageItem currentPage;

  /// Calls this function when an item of the navigation bar is selected.
  final Function(PageItem) onSelectedPage;

  const BottomNavBar({
    super.key,
    required this.currentPage,
    required this.onSelectedPage,
  });

  @override
  State<BottomNavBar> createState() => _BottomNavBarState();
}

class _NavEntry {
  final PageItem page;
  final String title;
  final String iconActive;
  final String iconInactive;

  const _NavEntry(this.page, this.title, this.iconActive, this.iconInactive);
}

class _BottomNavBarState extends State<BottomNavBar> {
  /// IMPORTANT: The order here has to match the order of the keys in
  /// `HomePageState.navigatorKeys`, because the PageView uses that order.
  static const List<_NavEntry> _entries = [
    _NavEntry(
      PageItem.feed,
      'Feed',
      'assets/img/icons/home-filled.png',
      'assets/img/icons/home-outlined.png',
    ),
    _NavEntry(
      PageItem.events,
      'Events',
      'assets/img/icons/calendar-filled.png',
      'assets/img/icons/calendar-outlined.png',
    ),
    _NavEntry(
      PageItem.mensa,
      'Mensa',
      'assets/img/icons/mensa-filled.png',
      'assets/img/icons/mensa-outlined.png',
    ),
    _NavEntry(
      PageItem.curatorial,
      'Curatorial',
      'assets/img/icons/curatorial-filled.png',
      'assets/img/icons/curatorial-outlined.png',
    ),
    _NavEntry(
      PageItem.navigation,
      'Navigation',
      'assets/img/icons/map-filled.png',
      'assets/img/icons/map-outlined.png',
    ),
    _NavEntry(
      PageItem.wallet,
      'Wallet',
      'assets/img/icons/wallet-filled.png',
      'assets/img/icons/wallet-outlined.png',
    ),
    _NavEntry(
      PageItem.more,
      'Mehr',
      'assets/img/icons/more.png',
      'assets/img/icons/more.png',
    ),
  ];

  /// Number of items that fit on the screen at once. A fractional value makes
  /// the next item peek in, so the user sees that the bar can be scrolled.
  static const double _visibleItems = 5.5;

  final ScrollController _scrollController = ScrollController();
  double _itemWidth = 0;

  @override
  void didUpdateWidget(covariant BottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPage != widget.currentPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Scrolls the bar so that the active item is centered (as far as possible).
  void _scrollToActive() {
    if (!mounted || !_scrollController.hasClients || _itemWidth == 0) return;
    final index = _entries.indexWhere((e) => e.page == widget.currentPage);
    if (index < 0) return;

    final viewport = _scrollController.position.viewportDimension;
    final target = (index * _itemWidth) - (viewport - _itemWidth) / 2;
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // 66 = 26 Icon + 2*8 Vertical Padding + 14 Label Text + 12 Active Animation
    const navbarHeight = 68.0;

    return Container(
      height: bottomInset + navbarHeight, // System UI + Campus App Navbar
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: Provider.of<ThemesNotifier>(context).currentThemeData.cardColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(15),
          topRight: Radius.circular(15),
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 5,
            offset: Offset(0, -1),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _itemWidth = constraints.maxWidth / _visibleItems;
          // Make sure the active item is visible right after the first layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients && _scrollController.offset == 0) {
              _scrollToActive();
            }
          });

          return SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in _entries)
                  SizedBox(
                    width: _itemWidth,
                    height: navbarHeight,
                    child: BottomNavBarItem(
                      title: e.title,
                      imagePathActive: e.iconActive,
                      imagePathInactive: e.iconInactive,
                      onTap: () => widget.onSelectedPage(e.page),
                      isActive: widget.currentPage == e.page,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
