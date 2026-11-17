---
name: Daily Discipline
description: Calm, adaptive habit tracker with agent-built habits
colors:
  teal-seed: "#0F766E"
  surface-light: "#F2F5F4"
  surface-dark: "#0B0F0E"
  card-light: "#FFFFFF"
  card-dark: "#131A19"
  field-light: "#E5ECEA"
  field-dark: "#1F2928"
  amber-light: "#B45309"
  amber-dark: "#FBBF24"
  amber-container-light: "#FEF3C7"
  amber-container-dark: "#3A2E14"
typography:
  headline:
    fontFamily: "Inter"
    fontWeight: 800
    letterSpacing: "-0.6px"
  title:
    fontFamily: "Inter"
    fontWeight: 700
    letterSpacing: "-0.4px"
  body:
    fontFamily: "Inter"
    fontWeight: 400
    letterSpacing: "-0.1px"
  label:
    fontFamily: "Inter"
    fontWeight: 600
rounded:
  field: "14px"
  tile: "12px"
  card: "24px"
  sheet: "28px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
components:
  button-default:
    rounded: "{rounded.field}"
    height: "40px"
    padding: "0 20px"
  button-compact:
    rounded: "{rounded.pill}"
    height: "34px"
    padding: "0 12px"
  button-primary-cta:
    rounded: "{rounded.field}"
    height: "50px"
  card:
    backgroundColor: "{colors.card-light}"
    rounded: "{rounded.card}"
    padding: "16px"
  count-badge:
    backgroundColor: "{colors.field-light}"
    rounded: "{rounded.pill}"
    padding: "4px 10px"
  input:
    backgroundColor: "{colors.field-light}"
    rounded: "{rounded.field}"
---

# Design System: Daily Discipline

## Overview

**Creative North Star: "The Quiet Morning"**

A calm, low-noise surface you glance at half-awake. Deep teal carries the brand, amber only signals "needs attention", and everything else steps back so the next due thing is obvious. Density is medium: cards group one topic each, actions inside cards are small, and only one action per screen is allowed to be large.

The app is adaptive. The brand layer (teal palette, Inter, rounded cards, the Today hero) is shared; the control layer follows the platform: Material 3 on Android, Cupertino switches, tab bar, alerts and progress indicators on iOS.

**Key Characteristics:**
- One large action per screen at most; in-card and row actions are compact.
- Tonal layering instead of shadows; the floating navigation bar is the only shadowed element.
- Drawn icons for app sections; emoji only for user/agent-created habits.
- Light and dark are equal citizens and follow the system by default.

## Colors

Material 3 scheme generated from the teal seed `#0F766E`, with custom surfaces and an amber tertiary.

- **Primary (teal):** brand, selection, progress, primary buttons.
- **Tertiary (amber):** setup banners, streak freezes and "Free" tags only. Never decorative.
- **Surfaces:** off-white `#F2F5F4` page with white cards (light); near-black `#0B0F0E` page with `#131A19` cards and a faint outline (dark).
- **Fields and badges:** `surfaceContainerHigh`.

## Typography

Inter (bundled), Material type scale. Headlines w800 with negative tracking, titles w700/w600, body w400 at -0.1. Counts and times use tabular figures. Respect system text scale; layouts use `TextScaler` for fixed-height tiles.

## Layout

- Page padding 16; cards stack with 14 between them; card padding 16.
- Today is ordered by what is due next; finished items collapse into "Done today".
- A screen title lives in the app bar (tab name), never repeated as a heading in the body.
- Minimum touch target 48dp (Android) / 44pt (iOS) regardless of visual size.

## Elevation & Depth

Flat. Hierarchy comes from surface tone (page → card → field). The floating navigation bar has one soft shadow (0 8 24, 8% light / 40% dark).

## Shapes

Cards 24, sheets and dialogs 28, fields and default buttons 14, icon tiles 12, compact buttons, chips and badges are pills.

## Components

- **Buttons:** default height 40. `compactButton` (34 visual, pill) for actions inside card rows, list items and card footers. `primaryButton` (50, full width) only for the single main action of a focused flow (onboarding, wake challenge).
- **SectionCard:** 36px tinted icon tile + title + optional `CountBadge`; children below.
- **CountBadge:** small pill for counts/times in a card header, replaces Chips.
- **Banners:** amber container, icon, one sentence, one text action.
- **Navigation:** floating rounded `NavigationBar` on Android; `CupertinoTabBar` on iOS.
- **Controls:** `Switch.adaptive`, `SwitchListTile.adaptive`, `Slider.adaptive`, `CircularProgressIndicator.adaptive`, `confirmDialog` (Material dialog / Cupertino alert).

## Do's and Don'ts

- Do keep one prominent action per screen; everything else compact or text.
- Do use drawn icons for app sections; keep emoji for habits the user or agent created.
- Do translate controls per platform instead of forcing Material on iOS.
- Don't put full-size filled buttons in list rows or card headers.
- Don't use Chips as static labels; use `CountBadge`.
- Don't repeat the screen title inside the body.
