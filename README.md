# IPL Mega Auction — Realtime Bidding, Rooms & Admin Panel

A full-stack **IPL Mega Auction** web application powered by **Supabase** (Postgres, Realtime, Row Level Security, and atomic PL/pgSQL RPCs) and designed for zero-build hosting on **GitHub Pages** or any static host.

## Features
- **Multi-Room Support**: Create custom auction rooms with configurable purse limits, hammer timer, bid increments, and Admin PINs, or join any room by code.
- **Auto-Seeded IPL Franchises & Players**: Every new room automatically seeds all 10 IPL franchises (₹120 Cr default purse) and 32 marquee & capped players.
- **Realtime Bidding & Anti-Sniping**: Uses Supabase Realtime (`postgres_changes`) and an atomic `place_bid` Postgres RPC to prevent race conditions, validate purses, and reset the hammer timer on new bids.
- **Admin Panel**: PIN-protected Auctioneer Console to put players on the block, pause/resume, extend timers (+15s), hammer SOLD/UNSOLD, re-queue unsold players, and add custom players.
- **Teams & Player Pool**: Live purse tracker, squad modals, and searchable/filterable player pool.

## Database Setup
The complete schema is in `supabase/schema.sql`.
