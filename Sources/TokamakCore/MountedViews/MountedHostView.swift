// Copyright 2018-2021 Tokamak contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//  Created by Max Desiatov on 03/12/2018.
//

/* A representation of a `View`, which has a `body` of type `Never`, stored in the tree of mounted
 views by `StackReconciler`.
 */
public final class MountedHostView<R: Renderer>: MountedElement<R> {
  /** Target of a closest ancestor host view. As a parent of this view
   might not be a host view, but a composite view, we need to pass
   around the target of a host view to its closests descendant host
   views. Thus, a parent target is not always the same as a target of
   a parent `View`. */
  private let parentTarget: R.TargetType

  /// Target of this host view supplied by a renderer after mounting has completed.
  private(set) var target: R.TargetType?

  init(
    _ view: AnyView,
    _ parentTarget: R.TargetType,
    _ environmentValues: EnvironmentValues,
    _ parent: MountedElement<R>?
  ) {
    self.parentTarget = parentTarget

    super.init(view, environmentValues, parent)
  }

  override func mount(
    before sibling: R.TargetType? = nil,
    on parent: MountedElement<R>? = nil,
    with reconciler: StackReconciler<R>
  ) {
    guard let target = reconciler.renderer.mountTarget(
      before: sibling,
      to: parentTarget,
      with: self
    )
    else { return }

    self.target = target

    guard !view.children.isEmpty else { return }

    mountedChildren = view.children.map {
      $0.makeMountedView(reconciler.renderer, target, environmentValues, self)
    }

    /* Remember that `GroupView`s are always "flattened", their `target` instances are targets of
     their parent elements. We need the insertion "cursor" `sibling` to be preserved when children
     are mounted in that case. Thus pass the `sibling` target to the children if `view` is a
     `GroupView`.
     */
    let isGroupView = view.type is GroupView.Type
    mountedChildren.forEach {
      $0.mount(before: isGroupView ? sibling : nil, on: self, with: reconciler)
    }
  }

  override func unmount(with reconciler: StackReconciler<R>) {
    guard let target = target else { return }

    reconciler.renderer.unmount(
      target: target,
      from: parentTarget,
      with: self
    ) {
      self.mountedChildren.forEach { $0.unmount(with: reconciler) }
    }
  }

  override func update(with reconciler: StackReconciler<R>) {
    guard let target = target else { return }

    updateEnvironment()
    target.view = view
    reconciler.renderer.update(target: target, with: self)

    var childrenViews = view.children

    switch (mountedChildren.isEmpty, childrenViews.isEmpty) {
    // if existing children present and new children array is empty
    // then unmount all existing children
    case (false, true):
      mountedChildren.forEach { $0.unmount(with: reconciler) }
      mountedChildren = []

    // if no existing children then mount all new children
    case (true, false):
      mountedChildren = childrenViews.map {
        $0.makeMountedView(reconciler.renderer, target, environmentValues, self)
      }
      mountedChildren.forEach { $0.mount(on: self, with: reconciler) }

    // if both arrays have items then reconcile by types and keys
    case (false, false):
      var newChildren = [MountedElement<R>]()

      // iterate through every `mountedChildren` element and compare with
      // a corresponding `childrenViews` element, remount if type differs, otherwise
      // run simple update
      while let mountedChild = mountedChildren.first, let childView = childrenViews.first {
        let newChild: MountedElement<R>
        if childView.typeConstructorName == mountedChildren[0].view.typeConstructorName {
          mountedChild.environmentValues = environmentValues
          mountedChild.view = childView
          mountedChild.updateEnvironment()
          mountedChild.update(with: reconciler)
          newChild = mountedChild
        } else {
          /* note the order of operations here: we mount the new child first, use the mounted child
            as a "cursor" sibling when mounting. Only then we can dispose of the old mounted child
            by unmounting it.
           */
          newChild = childView.makeMountedView(
            reconciler.renderer,
            target,
            environmentValues,
            self
          )
          newChild.mount(before: mountedChild.firstDescendantTarget, on: self, with: reconciler)
          mountedChild.unmount(with: reconciler)
        }
        newChildren.append(newChild)
        mountedChildren.removeFirst()
        childrenViews.removeFirst()
      }

      // more mounted views left than views were to be rendered:
      // unmount remaining `mountedChildren`
      if !mountedChildren.isEmpty {
        for child in mountedChildren {
          child.unmount(with: reconciler)
        }
      } else {
        // more views left than children were mounted,
        // mount remaining views
        for firstChild in childrenViews {
          let newChild: MountedElement<R> =
            firstChild.makeMountedView(reconciler.renderer, target, environmentValues, self)
          newChild.mount(on: self, with: reconciler)
          newChildren.append(newChild)
        }
      }

      mountedChildren = newChildren

    // both arrays are empty, nothing to reconcile
    case (true, true): ()
    }
  }
}
