<script setup lang="ts">
import { computed } from 'vue'
import { APIError } from '../api'

const props = defineProps<{ error: unknown }>()

const message = computed(() => (props.error instanceof Error ? props.error.message : String(props.error)))
const issues = computed(() => (props.error instanceof APIError ? props.error.issues : []))
</script>

<template>
  <div v-if="error" class="banner error" role="alert">
    {{ message }}
    <ul v-if="issues.length">
      <li v-for="issue in issues" :key="issue">{{ issue }}</li>
    </ul>
  </div>
</template>
