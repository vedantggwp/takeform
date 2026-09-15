# Root UI recipe

Run the copied app from a directory other than the repository. Record one screenshot and result for each scenario. The diagnostic page is not renderer proof.

| # | Scenario | Pass predicate |
|---:|---|---|
| 1 | Launch the copied app from another current directory | The window appears and the status names the missing configuration rather than a blank preview success. |
| 2 | Configure a Node executable, a cleared bundle root and a fixture root | The app accepts the grants only after explicit selection. No home path is rendered. |
| 3 | Load Diagnostic | The helper reports a loopback origin and the page says it is diagnostic. |
| 4 | Observe first frame | A displayed-frame acknowledgement and matched load request ID with latency appear after the page loads. Diagnostic responsiveness budget is at most 1,000 ms. |
| 5 | Seek to first frame | Requested and displayed both become frame 1 only after acknowledgement. |
| 6 | Seek to last frame | Requested and displayed both become the declared final frame only after acknowledgement. |
| 7 | Send rapid seeks | A delayed request, session or snapshot acknowledgement produces a stale notice and does not overwrite the current displayed frame. |
| 8 | Play and pause | Each control changes status only after the page acknowledgement. |
| 9 | Resize the window | Native controls remain reachable and the preview resizes without opening a popup. |
| 10 | Test missing bundle and helper failure | The app shows an actionable Node, bundle or helper error. It never treats a blank page as a passing preview. |

The diagnostic seek responsiveness budget is at most 250 ms from native request to diagnostic page acknowledgement on the recorded machine. It is a guardrail for the host only. Record first-frame and seek measurements for each real renderer later, with hardware, OS, Node, browser and renderer versions. Do not calculate a renderer performance ratio until both adapters are measured in this copied app and visually reviewed.
