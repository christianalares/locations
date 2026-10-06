# README images

The icon uses the app’s existing vector artwork, with rounded corners for display.

The screenshots show the real SwiftUI interface in an isolated iPhone Simulator.
All visits, journeys, times, distances, workouts, and calendar activity are
fabricated. Map labels come from Apple Maps. The example uses public Stockholm
landmarks: Stortorget, Mariatorget, Nordiska museet, and Djurgården. None of the
locations represent a person’s home or actual movements.

To capture them, a temporary copy of the app adapted the existing
`-blipDemoTimeline` fixtures to Stockholm. The paused-tracking warning was hidden
in that preview build so it could display the normal timeline layout without
enabling location capture. No server, device token, contacts, imported ledger,
or real phone was involved. The app source and built-in Null Island fixtures in
this repository are unchanged.

The timeline uses `-blipDemoTimeline`; the calendar also uses
`-blipDemoTimelineCalendar`. The preview date is fixed to 28 September 2026, and the simulator status bar
is set to 9:41.
