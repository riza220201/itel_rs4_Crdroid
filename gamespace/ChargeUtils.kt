/*
 * Copyright (C) 2021 Chaldeaprjkt
 *               2026 itel RS4 (S666LN) port
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.chaldeaprjkt.gamespace.utils

import android.util.Log
import java.io.File
import java.io.IOException
import javax.inject.Inject

/**
 * Bypass charging: let the adapter carry the system load directly instead of
 * charging the cell, so a long gaming session on the charger does not cook the
 * battery. Measured on this hardware at 18% on USB: battery current_now went
 * +400 mA -> ~0 mA on enable, and back to +423 mA on release. Current near zero
 * rather than strongly negative is what makes it a true bypass rather than
 * merely "charging stopped".
 *
 * The node is written directly rather than through an init "on property:"
 * trigger, which was the original plan. That plan is not implementable from
 * here: GameSpace is platform-signed with sharedUserId=android.uid.system, so it
 * runs as system_app, and system/sepolicy/private/property.te:324 neverallows
 * ANY coredomain but init from setting a vendor property -- no choice of vendor
 * property macro gets around it. Writing the node directly needs a single allow
 * rule and has the side benefit that state is read back from the hardware, so
 * the tile cannot drift out of sync with reality.
 *
 * Nothing here persists the setting. The node resets to 0 on reboot, so a crash
 * that skips the session-end restore can never leave a phone that silently
 * refuses to charge. The user's preference lives in AppSettings and is
 * re-applied when the next game session starts, the same split stayAwake uses.
 */
class ChargeUtils @Inject constructor() {

    private val node = File(NODE)

    /** False on any device whose charger driver lacks the node. */
    val isSupported: Boolean
        get() = node.exists()

    var bypass: Boolean
        get() = try {
            node.readText().trim() == "1"
        } catch (e: IOException) {
            false
        }
        set(enable) {
            try {
                node.writeText(if (enable) "1" else "0")
            } catch (e: IOException) {
                Log.e(TAG, "failed to toggle bypass charging", e)
            }
        }

    companion object {
        const val TAG = "GameSpace:ChargeUtils"
        const val NODE = "/sys/devices/platform/charger/tran_aichg_disable_charger"
    }
}
