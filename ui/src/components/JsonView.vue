<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{ value: unknown }>()
const text = computed(() => (props.value === undefined ? '—' : JSON.stringify(props.value, null, 2)))
</script>

<template>
  <pre class="json">{{ text }}</pre>
</template>
