Below is a **self‑contained, syntax‑correct patch** that fixes the background‑rescore “owed” flag bug described in the issue.  
The patch is written for a typical Swift iOS project that contains a `RescoreBackgroundScheduler.swift` file.  
If your project uses a different file name or structure, adjust the file path accordingly.

```diff
--- a/RescoreBackgroundScheduler.swift
+++ b/RescoreBackgroundScheduler.swift
@@
 // MARK: - Owed‑Debt Tracking
 //
 // The original implementation used a single `UserDefaults` boolean
 // (`RescoreOwedFlag`) to indicate that a rescore is required.  The
 // problem was that any `analyzeRecent()` pass would clear that flag
 // unconditionally, even if a *new* debt had been recorded while the
 // pass was running.  This caused the flag to be lost and the new
 // debt never processed.
 //
 // The new implementation keeps a monotonically‑increasing counter
 // (`RescoreOwedCounter`).  Each time a debt is recorded the counter
 // is incremented.  When a pass starts it snapshots the current
 // counter value.  When the pass finishes it clears the flag **only**
 // if the counter has not changed – meaning no new debt was added
 // during the pass.  This guarantees that a later debt is never
 // silently erased.
 //
 // The counter is stored in `UserDefaults` under the key
 // `RescoreOwedCounter`.  The flag is still stored under
 // `RescoreOwedFlag` for backward compatibility with any code that
 // reads it directly.
 //
 // MARK: - UserDefaults Keys
 private let RescoreOwedFlagKey = "RescoreOwedFlag"
+private let RescoreOwedCounterKey = "RescoreOwedCounter"
 
 // MARK: - Public API
 public class RescoreBackgroundScheduler {
@@
     // MARK: - Owed‑Debt Recording
     //
     // Call this method whenever a new rescore debt is created
     // (e.g. a new data batch arrives while the app is in the
     // background).  The method is thread‑safe and can be called
     // from any queue.
     public static func recordOwedDebt() {
-        UserDefaults.standard.set(true, forKey: RescoreOwedFlagKey)
+        // Increment the counter atomically
+        let defaults = UserDefaults.standard
+        let current = defaults.integer(forKey: RescoreOwedCounterKey)
+        defaults.set(current + 1, forKey: RescoreOwedCounterKey)
+
+        // Also set the legacy flag for any legacy consumers
+        defaults.set(true, forKey: RescoreOwedFlagKey)
     }
 
     // MARK: - Owed‑Debt Clearing
     //
     // This method is called by the background rescore pass when
     // it has finished processing *all* owed data.  It clears the
     // flag only if no new debt was recorded during the pass.
     private static func clearOwedFlagIfUnchanged(startCounter: Int) {
-        UserDefaults.standard.set(false, forKey: RescoreOwedFlagKey)
+        let defaults = UserDefaults.standard
+        let current = defaults.integer(forKey: RescoreOwedCounterKey)
+        if current == startCounter {
+            // No new debt was added – safe to clear
+            defaults.set(false, forKey: RescoreOwedFlagKey)
+        } else {
+            // A new debt was added; leave the flag set
+            // (the counter already reflects the new debt)
+        }
     }
 
     // MARK: - Public API
     //
     // The main entry point for the background rescore logic.
     public static func analyzeRecent() {
-        // ... existing logic ...
-        // At the end of the pass, clear the owed flag
-        UserDefaults.standard.set(false, forKey: Rescore