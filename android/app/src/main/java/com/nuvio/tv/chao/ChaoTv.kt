package com.nuvio.tv.chao

import android.content.Context
import com.nuvio.tv.data.local.AppOnboardingDataStore
import com.nuvio.tv.data.local.ExperienceModeDataStore
import com.nuvio.tv.data.local.LayoutPreferenceDataStore
import com.nuvio.tv.data.local.PlayerSettingsDataStore
import com.nuvio.tv.data.local.StreamAutoPlayMode
import com.nuvio.tv.domain.model.ExperienceMode
import com.nuvio.tv.domain.model.HomeLayout

/**
 * House switches for Chao TV on Google TV (fork of NuvioMedia/NuvioTV, GPL-3.0).
 * Mirrors the tvOS app's ChaoTV.swift: no accounts, one shared profile, no
 * Watch Party / third-party integrations, streams only via the house cache add-on.
 */
object ChaoTv {
    const val DISPLAY_NAME = "Chao TV"
    const val SKIPS_LOGIN = true
    const val SHOWS_THIRD_PARTY_INTEGRATIONS = false
    const val ALLOWS_P2P = false

    private const val PREFS = "chaotv_house"
    private const val KEY_DEFAULTS = "first_run_defaults_v1"

    /**
     * First launch only: skip the onboarding choices (sign-in QR, experience
     * mode, layout, essential add-on setup) and turn Auto Play on, so play and
     * resume start without the source picker - same as the Apple TV app.
     */
    suspend fun applyFirstRunDefaults(
        context: Context,
        onboarding: AppOnboardingDataStore,
        experience: ExperienceModeDataStore,
        layout: LayoutPreferenceDataStore,
        player: PlayerSettingsDataStore,
    ) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(KEY_DEFAULTS, false)) return
        onboarding.setHasSeenAuthQrOnFirstLaunch(true)
        experience.setMode(ExperienceMode.ADVANCED)
        experience.setAddonSetupSkipped(true)
        layout.setLayout(HomeLayout.MODERN)
        player.setStreamAutoPlayMode(StreamAutoPlayMode.FIRST_STREAM)
        prefs.edit().putBoolean(KEY_DEFAULTS, true).apply()
    }
}
