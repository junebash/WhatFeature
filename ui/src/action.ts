import { ref } from 'vue'

/** Runs async work with a busy flag and the last error, for buttons and forms. */
export function useAction() {
  const busy = ref(false)
  const error = ref<unknown>(null)

  async function run<T>(work: () => Promise<T>): Promise<T | undefined> {
    busy.value = true
    error.value = null
    try {
      return await work()
    } catch (caught) {
      error.value = caught
      return undefined
    } finally {
      busy.value = false
    }
  }

  return { busy, error, run }
}
