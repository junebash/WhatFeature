<script setup lang="ts">
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAction } from '../action'
import ErrorBanner from '../components/ErrorBanner.vue'
import { signIn } from '../session'

const favicon = `${import.meta.env.BASE_URL}favicon.svg`
const route = useRoute()
const router = useRouter()
const token = ref('')
const remember = ref(false)
const { busy, error, run } = useAction()

async function submit() {
  const done = await run(async () => {
    await signIn(token.value.trim(), remember.value)
    return true
  })
  if (done) await router.replace(typeof route.query.next === 'string' ? route.query.next : '/projects')
}
</script>

<template>
  <div class="sign-in">
    <form class="card" @submit.prevent="submit">
      <div class="card-body">
        <div class="row">
          <img :src="favicon" alt="" width="28" height="28" />
          <h1>WhatFeature</h1>
        </div>
        <p class="muted">Sign in with an admin token. Make one with <code>whatfeature tokens create --admin --name …</code>, or on the server with <code>whatfeature db token create --admin --name …</code>.</p>
        <label class="field">
          Admin token
          <input v-model="token" type="password" autocomplete="off" placeholder="wf_admin_…" required autofocus />
        </label>
        <label class="check small">
          <input v-model="remember" type="checkbox" />
          Remember on this device
        </label>
        <p class="muted small">Otherwise the token is forgotten when you close this tab.</p>
        <ErrorBanner :error="error" />
        <button class="primary" type="submit" :disabled="busy || !token.trim()">{{ busy ? 'Checking…' : 'Sign in' }}</button>
      </div>
    </form>
  </div>
</template>

<style scoped>
.sign-in { min-height: 100vh; display: grid; place-items: center; padding: 24px; }
form { width: min(420px, 100%); }
</style>
