<script setup lang="ts">
import { onMounted, ref } from 'vue'

// A native <dialog>: focus trapping, Escape and the backdrop come from the browser. Mount it with v-if; it opens
// itself and emits `close` when dismissed.
defineProps<{ title: string }>()
const emit = defineEmits<{ close: [] }>()

const dialog = ref<HTMLDialogElement>()
onMounted(() => dialog.value?.showModal())

function onBackdrop(event: MouseEvent) {
  if (event.target === dialog.value) emit('close')
}
</script>

<template>
  <dialog ref="dialog" @close="emit('close')" @mousedown="onBackdrop">
    <div class="dialog-header">
      <h2>{{ title }}</h2>
      <button class="ghost icon" aria-label="Close" @click="emit('close')">✕</button>
    </div>
    <div class="dialog-body">
      <slot />
    </div>
    <div v-if="$slots.footer" class="dialog-footer">
      <slot name="footer" />
    </div>
  </dialog>
</template>
