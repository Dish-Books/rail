const KEY = "rail:todos-open";

// Whether this browser left the to-dos panel open, read on every socket join.
export const readOpen = (storage) => storage.getItem(KEY) === "true";

export const writeOpen = (storage, open) => {
  if (open) storage.setItem(KEY, "true");
  else storage.removeItem(KEY);
};

export const TodosOpen = {
  mounted() {
    this.handleEvent("todos-open", ({ open }) => writeOpen(window.localStorage, open));
  }
};
