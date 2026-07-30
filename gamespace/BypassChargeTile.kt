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
package io.chaldeaprjkt.gamespace.widget.tiles

import android.content.Context
import android.util.AttributeSet
import android.view.View
import io.chaldeaprjkt.gamespace.R
import io.chaldeaprjkt.gamespace.utils.di.ServiceViewEntryPoint
import io.chaldeaprjkt.gamespace.utils.entryPointOf

class BypassChargeTile @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : BaseTile(context, attrs) {

    private val chargeUtils by lazy { context.entryPointOf<ServiceViewEntryPoint>().chargeUtils() }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // GameSpace is a shared crDroid app; only show the tile where the
        // charger driver actually exposes the node.
        if (!chargeUtils.isSupported) {
            visibility = GONE
            return
        }
        shouldBypass = appSettings.chargeBypass
        title?.text = context.getString(R.string.bypass_charge_title)
        icon?.setImageResource(R.drawable.ic_charge_bypass)
    }

    private var shouldBypass: Boolean = false
        set(value) {
            field = value
            if (value) {
                summary?.text = context.getString(R.string.state_enabled)
            } else {
                summary?.text = context.getString(R.string.state_disabled)
            }
            appSettings.chargeBypass = value
            isSelected = value
            chargeUtils.bypass = value
        }

    override fun onClick(v: View?) {
        super.onClick(v)
        shouldBypass = !shouldBypass
    }
}
