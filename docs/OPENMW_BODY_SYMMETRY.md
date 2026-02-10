# OpenMW Body Part Symmetry — How Mirroring Works

Reference document for how OpenMW handles the left/right symmetry of Morrowind NPC body parts, and how Godotwind's approach differs. All code snippets are verbatim from the OpenMW source in `inspos/openmw/`.

---

## The Problem

Morrowind stores body parts with NO left/right distinction in the ESM data. A single `BodyPart` record with `part_type = Hand` (5) provides geometry for **one side only** — the right side. The engine must produce the left side at runtime.

There is one exception: full-body "skin" meshes (e.g., `b_n_dark elf_m_body.nif`) are skinned to the full skeleton and already contain geometry for both sides via bone weights. These do NOT need mirroring.

---

## Enums Reference

### ESM::BodyPart::MeshPart (`components/esm3/loadbody.hpp`)

```cpp
enum MeshPart {
    MP_Head = 0, MP_Hair = 1, MP_Neck = 2, MP_Chest = 3, MP_Groin = 4,
    MP_Hand = 5, MP_Wrist = 6, MP_Forearm = 7, MP_Upperarm = 8,
    MP_Foot = 9, MP_Ankle = 10, MP_Knee = 11, MP_Upperleg = 12,
    MP_Clavicle = 13, MP_Tail = 14, MP_Count = 15
};
```

### ESM::PartReferenceType (`components/esm3/loadarmo.hpp`)

```cpp
enum PartReferenceType {
    PRT_Head = 0, PRT_Hair = 1, PRT_Neck = 2, PRT_Cuirass = 3,
    PRT_Groin = 4, PRT_Skirt = 5,
    PRT_RHand = 6, PRT_LHand = 7, PRT_RWrist = 8, PRT_LWrist = 9,
    PRT_Shield = 10,
    PRT_RForearm = 11, PRT_LForearm = 12, PRT_RUpperarm = 13, PRT_LUpperarm = 14,
    PRT_RFoot = 15, PRT_LFoot = 16, PRT_RAnkle = 17, PRT_LAnkle = 18,
    PRT_RKnee = 19, PRT_LKnee = 20, PRT_RLeg = 21, PRT_LLeg = 22,
    PRT_RPauldron = 23, PRT_LPauldron = 24,
    PRT_Weapon = 25, PRT_Tail = 26, PRT_Count = 27
};
```

Note: `PRT_Skirt`, `PRT_Shield`, `PRT_RPauldron`, `PRT_LPauldron`, `PRT_Weapon` are equipment-specific — they are NOT populated by race body parts.

---

## OpenMW's `sBodyPartMap` — The Multimap

In `apps/openmw/mwrender/npcanimation.cpp:1168-1179`, OpenMW defines `sBodyPartMap` as a **multimap** (one ESM part type maps to multiple slots):

```cpp
typedef std::multimap<ESM::BodyPart::MeshPart, ESM::PartReferenceType> BodyPartMapType;
static const BodyPartMapType sBodyPartMap = {
    { ESM::BodyPart::MP_Neck,     ESM::PRT_Neck },
    { ESM::BodyPart::MP_Chest,    ESM::PRT_Cuirass },
    { ESM::BodyPart::MP_Groin,    ESM::PRT_Groin },
    { ESM::BodyPart::MP_Hand,     ESM::PRT_RHand },
    { ESM::BodyPart::MP_Hand,     ESM::PRT_LHand },
    { ESM::BodyPart::MP_Wrist,    ESM::PRT_RWrist },
    { ESM::BodyPart::MP_Wrist,    ESM::PRT_LWrist },
    { ESM::BodyPart::MP_Forearm,  ESM::PRT_RForearm },
    { ESM::BodyPart::MP_Forearm,  ESM::PRT_LForearm },
    { ESM::BodyPart::MP_Upperarm, ESM::PRT_RUpperarm },
    { ESM::BodyPart::MP_Upperarm, ESM::PRT_LUpperarm },
    { ESM::BodyPart::MP_Foot,     ESM::PRT_RFoot },
    { ESM::BodyPart::MP_Foot,     ESM::PRT_LFoot },
    { ESM::BodyPart::MP_Ankle,    ESM::PRT_RAnkle },
    { ESM::BodyPart::MP_Ankle,    ESM::PRT_LAnkle },
    { ESM::BodyPart::MP_Knee,     ESM::PRT_RKnee },
    { ESM::BodyPart::MP_Knee,     ESM::PRT_LKnee },
    { ESM::BodyPart::MP_Upperleg, ESM::PRT_RLeg },
    { ESM::BodyPart::MP_Upperleg, ESM::PRT_LLeg },
    { ESM::BodyPart::MP_Tail,     ESM::PRT_Tail }
};
```

**Not in this map:** `MP_Head`, `MP_Hair`, `MP_Clavicle`. Head and hair are NPC-specific (see below). Clavicle/pauldron slots come from equipment only.

The same `ESM::BodyPart*` pointer is assigned to both the R and L slots. The attachment code decides how to handle each slot.

### How the Multimap Is Iterated — `getBodyParts()`

`npcanimation.cpp:1269-1275`:

```cpp
BodyPartMapType::const_iterator bIt
    = sBodyPartMap.lower_bound(BodyPartMapType::key_type(bodypart.mData.mPart));
while (bIt != sBodyPartMap.end() && bIt->first == bodypart.mData.mPart)
{
    parts[bIt->second] = &bodypart;
    ++bIt;
}
```

For a single ESM BodyPart with `mData.mPart == MP_Hand`, `lower_bound()` finds the first `MP_Hand` entry, then the while loop assigns the **same pointer** to both `parts[PRT_RHand]` and `parts[PRT_LHand]`.

### Head & Hair — NPC-Specific, Not Race-Based

Head and hair are NOT in `sBodyPartMap`. They come from the NPC record's own fields (`npcanimation.cpp:457-467`):

```cpp
const ESM::RefId headName = isWerewolf ? ESM::RefId::stringRefId("WerewolfHead") : mNpc->mHead;
const ESM::RefId hairName = isWerewolf ? ESM::RefId::stringRefId("WerewolfHair") : mNpc->mHair;
```

Each NPC stores its specific head and hair BodyPart IDs. Only werewolves override with hardcoded names. Hair attaches to the "Head" bone with a `"hair"` filter for `CopyRigVisitor`.

---

## `sPartList` — PRT-to-Bone-Name Mapping

OpenMW maps each `PartReferenceType` to an **attachment bone name** (`npcanimation.cpp:236-251`). These are NOT the NIF skeleton bone names — they are OpenMW's own naming convention:

```cpp
static const inline NpcAnimation::PartBoneMap sPartList = {
    { ESM::PRT_Head,       "Head" },
    { ESM::PRT_Hair,       "Head" },           // uses "hair" filter
    { ESM::PRT_Neck,       "Neck" },
    { ESM::PRT_Cuirass,    "Chest" },
    { ESM::PRT_Groin,      "Groin" },
    { ESM::PRT_Skirt,      "Groin" },
    { ESM::PRT_RHand,      "Right Hand" },
    { ESM::PRT_LHand,      "Left Hand" },
    { ESM::PRT_RWrist,     "Right Wrist" },
    { ESM::PRT_LWrist,     "Left Wrist" },
    { ESM::PRT_Shield,     "Shield Bone" },
    { ESM::PRT_RForearm,   "Right Forearm" },
    { ESM::PRT_LForearm,   "Left Forearm" },
    { ESM::PRT_RUpperarm,  "Right Upper Arm" },
    { ESM::PRT_LUpperarm,  "Left Upper Arm" },
    { ESM::PRT_RFoot,      "Right Foot" },
    { ESM::PRT_LFoot,      "Left Foot" },
    { ESM::PRT_RAnkle,     "Right Ankle" },
    { ESM::PRT_LAnkle,     "Left Ankle" },
    { ESM::PRT_RKnee,      "Right Knee" },
    { ESM::PRT_LKnee,      "Left Knee" },
    { ESM::PRT_RLeg,       "Right Upper Leg" },
    { ESM::PRT_LLeg,       "Left Upper Leg" },
    { ESM::PRT_RPauldron,  "Right Clavicle" },
    { ESM::PRT_LPauldron,  "Left Clavicle" },
    { ESM::PRT_Weapon,     "Weapon Bone" },
    { ESM::PRT_Tail,       "Tail" }
};
```

**Two naming systems exist (don't conflate them):**
- **NIF skeleton bones:** `"Bip01 L Hand"`, `"Bip01 R Forearm"` — used for skinning/bone weights
- **sPartList attachment bones:** `"Left Hand"`, `"Right Forearm"` — OpenMW's own names for attachment nodes

The `"Left"` substring check in `attach()` operates on sPartList names, NOT NIF bone names.

---

## Two Attachment Paths in `attach.cpp`

OpenMW's `SceneUtil::attach()` function (`components/sceneutil/attach.cpp:114-200`) has two distinct paths. The branch condition is whether the NIF's **root node** is a `Skeleton` type:

### Path A — Skeleton Root (CopyRigVisitor)

```cpp
if (dynamic_cast<const SceneUtil::Skeleton*>(toAttach.get()))
{
    osg::ref_ptr<osg::Group> handle = new osg::Group;

    CopyRigVisitor copyVisitor(handle, filter);
    const_cast<osg::Node*>(toAttach.get())->accept(copyVisitor);
    copyVisitor.doCopy(sceneManager);

    handle->getOrCreateUserDataContainer()->addUserObject(new Resource::TemplateRef(toAttach));

    if (handle->getNumChildren() == 1)
    {
        osg::ref_ptr<osg::Node> newHandle = handle->getChild(0);
        handle->removeChild(newHandle);
        master->asGroup()->addChild(newHandle);
        return newHandle;
    }
    else
    {
        master->asGroup()->addChild(handle);
        return handle;
    }
}
```

`CopyRigVisitor` (`attach.cpp:22-83`) traverses the scene graph, finds all `RigGeometry` / `RigGeometryHolder` drawables matching a name filter, and copies their subtrees into a Group that gets added to the master skeleton. **No mirroring is applied** — full-body skins already have geometry for both sides.

This path handles:
- Full-body "skin" meshes (e.g., `b_n_dark elf_m_body.nif`) whose root is a Skeleton node
- The condition is `Skeleton` root type, NOT the presence of NiSkinInstance/NiSkinData

### Path B — Non-Skeleton Root (PositionAttitudeTransform)

```cpp
else
{
    osg::ref_ptr<osg::Node> clonedToAttach = sceneManager->getInstance(toAttach);

    FindByNameVisitor findBoneOffset("BoneOffset");
    clonedToAttach->accept(findBoneOffset);

    osg::ref_ptr<osg::PositionAttitudeTransform> trans;

    if (findBoneOffset.mFoundNode)
    {
        osg::MatrixTransform* boneOffset = dynamic_cast<osg::MatrixTransform*>(findBoneOffset.mFoundNode);
        if (!boneOffset)
            throw std::runtime_error("BoneOffset must be a MatrixTransform");

        trans = new osg::PositionAttitudeTransform;
        trans->setPosition(boneOffset->getMatrix().getTrans());

        if (boneOffset->getNumChildren() == 0 && boneOffset->getNumParents() == 1)
            boneOffset->getParent(0)->removeChild(boneOffset);
    }

    if (attachNode->getName().find("Left") != std::string::npos)
    {
        if (!trans)
            trans = new osg::PositionAttitudeTransform;
        trans->setScale(osg::Vec3f(-1.f, 1.f, 1.f));

        // Need to invert culling because of the negative scale
        // Note: for absolute correctness we would need to check the current front face
        // for every mesh then invert it However MW isn't doing this either, so don't.
        // Assuming all meshes are using backface culling is more efficient.
        static const osg::ref_ptr<osg::StateSet> frontFaceStateSet = makeFrontFaceStateSet();
        trans->setStateSet(frontFaceStateSet);
    }

    if (trans)
    {
        attachNode->addChild(trans);
        trans->addChild(clonedToAttach);
        return trans;
    }
    else
    {
        attachNode->addChild(clonedToAttach);
        return clonedToAttach;
    }
}
```

Key details:
1. **`scale(-1, 1, 1)`** — Flips the X axis to mirror the mesh from right to left
2. **`FrontFace::CLOCKWISE`** — Reverses the winding order so that back-face culling works correctly on the mirrored geometry. Without this, the mirrored triangles would be culled as back-facing.
3. **BoneOffset** — Some NIFs contain a node named `"BoneOffset"` (a `MatrixTransform`). OpenMW extracts its translation and applies it to the attachment transform, then removes the node.
4. **Left detection** — `attachNode->getName().find("Left")` checks the **sPartList attachment bone name** (e.g., `"Left Hand"`), not the NIF bone name. All left-side sPartList names contain `"Left"`.

### Why This Works in OpenSceneGraph (But Not Godot)

OpenSceneGraph (OSG) computes the normal matrix as `transpose(inverse(modelViewMatrix))`. When the model matrix has a negative determinant (from `scale(-1,1,1)`), the inverse-transpose correctly flips the normals. Combined with `FrontFace::CLOCKWISE`, this produces correct lighting on mirrored geometry.

OpenMW does NOT have special CPU-side normal flipping code — it relies entirely on OSG's normal matrix. The comment in the source even admits they don't check per-mesh front face and assume all MW meshes use backface culling.

**Godot does NOT do this.** Godot's `MODEL_NORMAL_MATRIX` does not account for negative-determinant transforms, so normals remain pointing in their original direction even after the X-axis mirror. This is why the `CULL_FRONT` approach (directly porting OpenMW's technique) produced dark/wrong-lit left-side parts in Godotwind.

---

## NIF Skin Data Pipeline

For skinned meshes, the NIF file contains:

### NiSkinInstance (`components/nif/data.hpp`)
- References a `NiSkinData`, a root bone (`NiAVObject`), and a list of bone `NiAVObject` pointers

### NiSkinData (`components/nif/data.hpp`)

```cpp
struct NiSkinData : public Record
{
    using VertWeight = std::pair<unsigned short, float>;

    struct BoneInfo
    {
        NiTransform mTransform;          // inverse bind matrix
        osg::BoundingSpheref mBoundSphere;
        std::vector<VertWeight> mWeights; // (vertex_index, weight) pairs
    };

    NiTransform mTransform;              // mesh-to-skeleton-root transform
    std::vector<BoneInfo> mBones;
};
```

- **`mTransform`** (top-level) — Transform from mesh space to skeleton root space
- **`BoneInfo::mTransform`** — Per-bone inverse bind matrix (bone-local space)
- **`BoneInfo::mWeights`** — Array of `(vertex_index, weight)` pairs

### OpenMW Skinning Formula (`components/sceneutil/riggeometry.cpp:165-206`)

At runtime, OpenMW computes (CPU-side, not GPU):

```
// Per-bone matrix: inverse bind * current bone world matrix
boneMat[i] = boneInfo[i].mInvBindMatrix * bone[i].mMatrixInSkeletonSpace

// Skin transform (applied once, not per-bone)
transform = mData->mTransform   // or mSkinToSkelMatrix * mData->mTransform

// Per-vertex: weighted blend of bone matrices, then apply skin transform
resultMat = sum(boneMat[i] * weight[i])  for each influencing bone
resultMat = resultMat * transform

finalPosition = resultMat * originalPosition
finalNormal   = transform3x3(originalNormal, resultMat)
```

The skin transform is a **post-multiply on the blended result**, not composed per-bone.

### NIF-to-OSG Conversion (`components/nifosg/nifloader.cpp:1601-1630`)

During NIF loading, any geometry with `NiSkinInstance` creates a `RigGeometry`:

```cpp
if (!niGeometry->mSkin.empty())
{
    osg::ref_ptr<SceneUtil::RigGeometry> rig(new SceneUtil::RigGeometry);
    rig->setSourceGeometry(geom);

    const Nif::NiSkinInstance* skin = niGeometry->mSkin.getPtr();
    const Nif::NiSkinData* data = skin->mData.getPtr();
    const Nif::NiAVObjectList& bones = skin->mBones;

    for (std::size_t i = 0; i < bones.size(); ++i)
    {
        boneInfo[i].mName = Misc::StringUtils::lowerCase(bones[i].getPtr()->mName);
        boneInfo[i].mInvBindMatrix = data->mBones[i].mTransform.toMatrix();
        // ...
    }
    rig->setBoneInfo(std::move(boneInfo));
    rig->setInfluences(influences);
    rig->setTransform(data->mTransform.toMatrix());
}
```

This means even individual limb NIFs with NiSkinData get converted to RigGeometry. But whether that RigGeometry is actually USED for skinning depends on the attachment path (see below).

---

## Individual Limb Parts vs Full-Body Skins

This is a critical distinction that determines which attachment path is used:

### Full-Body Skins (Path A — Skeleton Root, No Mirroring)
- Files like `b_n_dark elf_m_body.nif`, `b_n_wood elf_f_body.nif`
- Contain geometry for the **entire body** — both left and right sides
- Skinned to the full skeleton with bone weights for L and R bones
- NIF root is a `Skeleton` node → triggers Path A
- `CopyRigVisitor` copies them directly; no mirroring needed
- These are the default "naked" body meshes

### Individual Limb Parts (Path B — Non-Skeleton Root, Mirrored)
- Files like `b_n_dark elf_m_upper arm.nif`, `b_n_dark elf_m_foot.nif`
- Contain geometry for **one side only** (the right side)
- May contain NiSkinData/RigGeometry, but their NIF root is NOT a Skeleton
- Because root is not Skeleton → goes through Path B (static attachment)
- The RigGeometry is cloned but never activated for skinning — it's rendered as a static mesh
- Left-side copies get the `scale(-1,1,1)` + `CLOCKWISE` winding treatment

### Why the Root Node Type Matters

The `attach()` branch condition is `dynamic_cast<const SceneUtil::Skeleton*>(toAttach.get())`. Full-body skin NIFs have a Skeleton at the root because they define the entire skeletal hierarchy. Individual limb NIFs only contain the mesh geometry (possibly with skin data referencing a few bones), but their root is a plain Group or MatrixTransform — not a Skeleton. This is what routes them to the static path regardless of whether they contain RigGeometry.

---

## Equipment Override System

Race body parts are the fallback. Equipment (clothing/armor) can override them (`npcanimation.cpp:586-671`):

### Priority System
```cpp
// Race body parts are added at priority 1
if (mPartPriorities[part] < 1)
    addOrReplaceIndividualPart(part, -1, 1, bodypart->mModel);

// Equipment parts override at higher priority
```

### Gender Variants (`components/esm3/loadarmo.hpp`)
Each equipment `PartReference` stores two body part IDs:
```cpp
struct PartReference {
    unsigned char mPart;    // PartReferenceType (0-26)
    RefId mMale, mFemale;   // separate body part IDs per gender
};
```

Female NPCs prefer `mFemale`, falling back to `mMale`. Male NPCs use `mMale` directly.

---

## Godotwind's Approach (Differs from OpenMW)

Because Godot's normal matrix doesn't handle negative-determinant transforms, Godotwind cannot use OpenMW's `scale(-1,1,1)` + `FrontFace::CLOCKWISE` approach directly. Instead:

### Static Parts (Non-Skinned)
1. Create a **mirrored copy** of the mesh data:
   - Flip normal X components: `normal.x = -normal.x`
   - Reverse triangle winding: swap `indices[i+1]` and `indices[i+2]` for each triangle
2. Apply the standard X-axis mirror transform for positioning (`scale(-1,1,1)`)
3. Use default `CULL_BACK` — the pre-flipped normals and reversed winding make it work correctly

### Skinned Parts (Single-Sided Limbs)
1. Create a **mirrored copy** of the mesh data:
   - Flip vertex X positions: `vertex.x = -vertex.x`
   - Flip normal X components: `normal.x = -normal.x`
   - Reverse triangle winding
   - Remap bone names: `" R "` ↔ `" L "` (e.g., `"bip01 r forearm"` → `"bip01 l forearm"`)
   - Use the skeleton's rest poses for the left-side bones as inverse bind matrices
2. Create a new `Skin` resource with the remapped bone names and new inverse binds
3. Attach as a `MeshInstance3D` with the mirrored skin — no transform mirror needed since the vertices are already flipped

### Full-Body Skins (Both Sides Already Present)
- Attached directly with their original skin data, no mirroring — same as OpenMW's Path A

---

## Reference: OpenMW Source Files

| File | Purpose |
|------|---------|
| `apps/openmw/mwrender/npcanimation.cpp` | `sBodyPartMap`, `sPartList`, `getBodyParts()`, `updateNpcBase()`, NPC assembly |
| `components/sceneutil/attach.cpp` | `attach()` with skinned/static paths, `CopyRigVisitor`, `makeFrontFaceStateSet()` |
| `components/sceneutil/riggeometry.cpp` | `RigGeometry` runtime CPU skinning |
| `components/nifosg/nifloader.cpp` | NIF→OSG conversion, `RigGeometry` creation from NiSkinData |
| `components/nif/data.hpp` | `NiSkinInstance`, `NiSkinData`, `NiTransform` structures |
| `components/esm3/loadbody.hpp` | `ESM::BodyPart` record, `MeshPart` enum |
| `components/esm3/loadarmo.hpp` | `PartReferenceType` enum, `PartReference` struct |
| `components/sceneutil/skeleton.cpp` | Bone lookup by lowercase name |
